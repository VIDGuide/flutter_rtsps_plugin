import Foundation
import VideoToolbox
import CoreMedia
import os.log

// MARK: - H264Decoder

/// Decodes H.264 NAL units to `CVPixelBuffer` via VideoToolbox.
///
/// Usage:
/// 1. Create with `init(onPixelBuffer:onError:)`.
/// 2. Call `initializeDecoder(sps:pps:)` when SPS/PPS are available (from SDP).
/// 3. Feed NAL units via `feedNalUnit(_:isFrameComplete:)` — this is the
///    callback target for `RtpDemuxer.onNalUnit`.
/// 4. Call `stop()` to release VideoToolbox resources.
///
/// Thread safety: all mutable state is protected by a serial `DispatchQueue`.
///
/// Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 4.7
final class H264Decoder {

    // MARK: - Callbacks

    /// Called on the decoder queue when a decoded frame is ready. (Req 4.3)
    let onPixelBuffer: (CVPixelBuffer) -> Void

    /// Called only for fatal errors (decoder init failure). (Req 4.4)
    private let onError: (Error) -> Void

    // MARK: - Private state

    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?

    /// Accumulates NAL units for the current access unit (frame).
    private var pendingNalUnits: [Data] = []

    /// True once `initializeDecoder` has succeeded.
    private var isInitialized = false

    /// Buffered SPS/PPS for in-band detection — stored until both are seen.
    private var inBandSps: Data?
    private var inBandPps: Data?

    private let queue = DispatchQueue(label: "com.pandawatch.flutter_rtsps_plugin.h264decoder",
                                     qos: .userInteractive)
    private let log = OSLog(subsystem: "com.pandawatch.flutter_rtsps_plugin", category: "H264Decoder")

    // MARK: - Init

    /// - Parameters:
    ///   - onPixelBuffer: Called with each decoded `CVPixelBuffer`.
    ///   - onError: Called only for fatal errors (decoder init failure).
    init(onPixelBuffer: @escaping (CVPixelBuffer) -> Void,
         onError: @escaping (Error) -> Void) {
        self.onPixelBuffer = onPixelBuffer
        self.onError = onError
    }

    // MARK: - Decoder Initialization

    /// Creates `CMVideoFormatDescription` and `VTDecompressionSession` from
    /// the provided SPS and PPS parameter sets. (Req 4.1)
    ///
    /// Must be called before `feedNalUnit` starts being invoked (i.e. before
    /// the demuxer is started). After that point, all state mutations happen
    /// on `queue` via `feedNalUnit`'s async dispatch.
    ///
    /// - Throws: `RtspError.decoderError` if VideoToolbox initialization fails.
    func initializeDecoder(sps: Data, pps: Data) throws {
        // Called from RtspStreamSession.start() before the demuxer is running,
        // so no concurrent feedNalUnit calls exist yet — run inline, no dispatch needed.
        try initializeDecoderSync(sps: sps, pps: pps)
    }

    /// Internal implementation — must be called on `queue`.
    private func initializeDecoderSync(sps: Data, pps: Data) throws {
        // Build the format description from SPS + PPS
        var spsBytes = [UInt8](sps)
        var ppsBytes = [UInt8](pps)

        var formatDesc: CMVideoFormatDescription?
        let status: OSStatus = spsBytes.withUnsafeBufferPointer { spsPtr in
            ppsBytes.withUnsafeBufferPointer { ppsPtr in
                var ptrs: [UnsafePointer<UInt8>] = [spsPtr.baseAddress!, ppsPtr.baseAddress!]
                var sizes: [Int] = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil,
                    parameterSetCount: 2,
                    parameterSetPointers: &ptrs,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDesc
                )
            }
        }

        guard status == noErr, let desc = formatDesc else {
            os_log("H264Decoder: CMVideoFormatDescriptionCreateFromH264ParameterSets failed: %d",
                   log: log, type: .error, status)
            throw RtspError.decoderError
        }

        // Tear down any existing session before creating a new one
        tearDownSession()

        // Pixel buffer attributes: 32BGRA output, IOSurface-backed (Req 4.1)
        let pixelBufferAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]

        // Callback record — uses a C-compatible closure via Unmanaged
        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: decompressionOutputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        var session: VTDecompressionSession?
        let sessionStatus = VTDecompressionSessionCreate(
            allocator: nil,
            formatDescription: desc,
            decoderSpecification: nil,
            imageBufferAttributes: pixelBufferAttrs as CFDictionary,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &session
        )

        guard sessionStatus == noErr, let sess = session else {
            os_log("H264Decoder: VTDecompressionSessionCreate failed: %d",
                   log: log, type: .error, sessionStatus)
            throw RtspError.decoderError
        }

        formatDescription = desc
        decompressionSession = sess
        isInitialized = true
        os_log("H264Decoder: decoder initialized", log: log, type: .info)
    }

    // MARK: - NAL Unit Feed (main entry point)

    /// Main entry point called by `RtpDemuxer.onNalUnit`. Accumulates NAL
    /// units and decodes when the access unit is complete (marker bit set).
    ///
    /// Also detects in-band SPS (type 7) and PPS (type 8) and initializes
    /// the decoder on first occurrence if not yet initialized. (Req 4.7)
    func feedNalUnit(_ nalUnit: Data, isFrameComplete: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.feedNalUnitSync(nalUnit, isFrameComplete: isFrameComplete)
        }
    }

    private func feedNalUnitSync(_ nalUnit: Data, isFrameComplete: Bool) {
        let stripped = stripAnnexBStartCode(from: nalUnit)
        guard !stripped.isEmpty else { return }

        let nalType = stripped[0] & 0x1F

        // Detect in-band SPS (type 7) and PPS (type 8) (Req 4.7)
        switch nalType {
        case 7:
            inBandSps = stripped
            tryInitializeFromInBand()
            return  // SPS is a parameter set, not a picture NAL — don't decode
        case 8:
            inBandPps = stripped
            tryInitializeFromInBand()
            return  // PPS is a parameter set, not a picture NAL — don't decode
        default:
            break
        }

        // Only queue picture NAL units if decoder is ready
        guard isInitialized else { return }

        pendingNalUnits.append(stripped)

        if isFrameComplete {
            let units = pendingNalUnits
            pendingNalUnits = []
            decodeNalUnits(units)
        }
    }

    // MARK: - Access Unit Decode

    /// Builds a `CMSampleBuffer` in AVCC format and submits it to the
    /// `VTDecompressionSession`. (Req 4.2)
    private func decodeNalUnits(_ nalUnits: [Data]) {
        guard let session = decompressionSession,
              let formatDesc = formatDescription,
              !nalUnits.isEmpty else { return }

        // Build AVCC block buffer: each NAL unit prefixed with 4-byte BE length
        var avccData = Data()
        for nal in nalUnits {
            let length = UInt32(nal.count)
            avccData.append(UInt8((length >> 24) & 0xFF))
            avccData.append(UInt8((length >> 16) & 0xFF))
            avccData.append(UInt8((length >> 8) & 0xFF))
            avccData.append(UInt8(length & 0xFF))
            avccData.append(contentsOf: nal)
        }

        // Create CMBlockBuffer — use CMBlockBufferCreateWithMemoryBlock with the
        // default allocator (nil) so CoreMedia *copies* the data into its own
        // allocation. Using kCFAllocatorNull here would hand CoreMedia a pointer
        // into our local `avccData` without copying it; since we use
        // _EnableAsynchronousDecompression the local Data goes out of scope
        // before VideoToolbox finishes reading it, causing a use-after-free and
        // corrupted frames.
        let avccLength = avccData.count
        var blockBuffer: CMBlockBuffer?
        let blockStatus: OSStatus = avccData.withUnsafeBytes { src in
            // CMBlockBufferCreateWithMemoryBlock with a nil blockAllocator copies
            // the bytes into a new CoreMedia-managed allocation.
            var copied: CMBlockBuffer?
            let s = CMBlockBufferCreateWithMemoryBlock(
                allocator: nil,
                memoryBlock: nil,          // let CoreMedia allocate
                blockLength: avccLength,
                blockAllocator: nil,       // CoreMedia owns the memory
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: avccLength,
                flags: 0,
                blockBufferOut: &copied
            )
            guard s == kCMBlockBufferNoErr, let dst = copied else { return s }
            // Copy our bytes into the CoreMedia-owned block
            let replaceStatus = CMBlockBufferReplaceDataBytes(
                with: src.baseAddress!,
                blockBuffer: dst,
                offsetIntoDestination: 0,
                dataLength: avccLength
            )
            if replaceStatus == kCMBlockBufferNoErr {
                blockBuffer = dst
            }
            return replaceStatus
        }

        guard blockStatus == kCMBlockBufferNoErr, let block = blockBuffer else {
            os_log("H264Decoder: CMBlockBuffer creation failed: %d",
                   log: log, type: .error, blockStatus)
            return  // Per-frame error: discard and continue (Req 4.5)
        }

        // Create CMSampleBuffer
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = avccLength
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: nil,
            dataBuffer: block,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleStatus == noErr, let sample = sampleBuffer else {
            os_log("H264Decoder: CMSampleBufferCreateReady failed: %d",
                   log: log, type: .error, sampleStatus)
            return  // Per-frame error: discard and continue (Req 4.5)
        }

        // Submit to VTDecompressionSession (Req 4.2)
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: [._EnableAsynchronousDecompression],
            frameRefcon: nil,
            infoFlagsOut: nil
        )

        if decodeStatus != noErr {
            os_log("H264Decoder: VTDecompressionSessionDecodeFrame failed: %d",
                   log: log, type: .error, decodeStatus)
            // Per-frame error: discard and continue (Req 4.5)
        }
    }

    // MARK: - Stop

    /// Invalidates the `VTDecompressionSession` and releases all resources. (Req 4.6)
    func stop() {
        queue.async { [weak self] in
            self?.tearDownSession()
        }
    }

    // MARK: - Private Helpers

    private func tearDownSession() {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
            os_log("H264Decoder: VTDecompressionSession invalidated", log: log, type: .info)
        }
        formatDescription = nil
        isInitialized = false
        pendingNalUnits = []
    }

    /// Initializes (or re-initializes) the decoder once both in-band SPS and
    /// PPS have been received.
    ///
    /// Re-initialization is intentionally allowed: mid-stream SPS/PPS changes
    /// (e.g. resolution or bitrate switch at a keyframe boundary) must cause a
    /// decoder reset. Continuing with stale parameter sets produces corrupted
    /// frames. Pending NAL units from the previous parameter set are flushed
    /// before teardown since they cannot be decoded with the new format
    /// description. (Req 4.7)
    private func tryInitializeFromInBand() {
        guard let sps = inBandSps, let pps = inBandPps else { return }

        // Discard any picture NALs that were queued under the old parameter sets.
        pendingNalUnits = []

        do {
            try initializeDecoderSync(sps: sps, pps: pps)
            inBandSps = nil
            inBandPps = nil
        } catch {
            os_log("H264Decoder: in-band decoder init failed: %{public}@",
                   log: log, type: .error, error.localizedDescription)
            onError(error)
        }
    }

    /// Strips Annex B start codes ([0,0,0,1] or [0,0,1]) from the front of a
    /// NAL unit. Returns the data unchanged if no start code is present. (Req 4.7)
    private func stripAnnexBStartCode(from data: Data) -> Data {
        if data.count >= 4,
           data[0] == 0x00, data[1] == 0x00,
           data[2] == 0x00, data[3] == 0x01 {
            return data.dropFirst(4)
        }
        if data.count >= 3,
           data[0] == 0x00, data[1] == 0x00, data[2] == 0x01 {
            return data.dropFirst(3)
        }
        return data
    }
}

// MARK: - VTDecompressionOutputCallback (C callback)

/// C-compatible callback invoked by VideoToolbox when a frame is decoded.
/// Bridges back into the Swift `H264Decoder` instance via `Unmanaged`. (Req 4.3)
private func decompressionOutputCallback(
    decompressionOutputRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTDecodeInfoFlags,
    imageBuffer: CVImageBuffer?,
    presentationTimeStamp: CMTime,
    presentationDuration: CMTime
) {
    guard let refCon = decompressionOutputRefCon else { return }
    let decoder = Unmanaged<H264Decoder>.fromOpaque(refCon).takeUnretainedValue()

    guard status == noErr else {
        // Per-frame decode error: discard frame, continue (Req 4.5)
        os_log("H264Decoder: decode callback error: %d",
               log: OSLog(subsystem: "com.pandawatch.flutter_rtsps_plugin", category: "H264Decoder"),
               type: .error, status)
        return
    }

    guard let pixelBuffer = imageBuffer else { return }
    decoder.onPixelBuffer(pixelBuffer)
}
