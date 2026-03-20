import Foundation
import os.log

// MARK: - RtpStats

/// Statistics tracked from received RTP packets, used by RtcpSender to build
/// Receiver Report packets (Req 3.2).
struct RtpStats {
    var ssrc: UInt32
    var highestSeq: UInt32
    var packetCount: UInt32
    var octetCount: UInt32
    /// RTP timestamp from the most recent packet (clock rate units).
    /// Used by RtcpSender to compute interarrival jitter per RFC 3550 §6.4.1.
    var rtpTimestamp: UInt32 = 0
    /// Wall-clock arrival time of the most recent packet (seconds, monotonic).
    /// Used together with `rtpTimestamp` for jitter computation.
    var arrivalTime: Double = 0
}

// MARK: - RtpDemuxer

/// Reads the TCP interleaved RTP/RTCP byte stream from an `RtspTransport` and
/// dispatches NAL units and RTCP packets to their respective consumers.
///
/// TCP interleaved framing (RFC 2326 §10.12):
///   0x24  |  channel (1 byte)  |  length (2 bytes, big-endian)  |  payload
///
/// Channel 0 → RTP  → H264Decoder callback (Req 2.2)
/// Channel 1 → RTCP → RtcpSender callback  (Req 2.3)
final class RtpDemuxer {

    // MARK: - Callbacks

    /// Called with each extracted NAL unit and a flag indicating whether the
    /// RTP marker bit was set (i.e. the access unit / frame is complete).
    /// (Req 2.4, 2.5, 2.7)
    var onNalUnit: ((Data, Bool) -> Void)?

    /// Called with each raw RTCP packet payload. (Req 2.3)
    var onRtcpPacket: ((Data) -> Void)?

    /// Called after each RTP packet is processed with updated statistics.
    /// Used by RtcpSender to populate Receiver Report fields. (Req 3.2)
    var onRtpStats: ((RtpStats) -> Void)?

    /// When `true`, the demuxer reads and discards TCP interleaved RTP data
    /// without processing it. RTCP packets (channel 1) are still forwarded.
    /// Used when UDP transport is active — the TCP read loop must continue
    /// to drain the kernel receive buffer (preventing the server's send
    /// buffer from filling and stalling the encoder) but the actual video
    /// data arrives via UDP.
    var drainOnly = false

    // MARK: - Private state

    private let transport: RtspTransport
    private var running = false
    /// Lock protecting reads/writes of `running` across the read-loop Task
    /// and callers of `stop()` from arbitrary threads (Req 2.3).
    private let runLock = NSLock()

    /// FU-A reassembly buffer. Holds the reconstructed NAL header byte followed
    /// by accumulated fragment payloads. (Req 2.7)
    private var fuaBuffer: Data?

    /// The sequence number of the last RTP packet processed, used to detect gaps
    /// within a FU-A reassembly sequence.
    private var lastSeq: UInt32? = nil

    /// Number of 16-bit sequence number wraparound cycles observed, used to
    /// compute the extended highest sequence number per RFC 3550 (Defect 1.28).
    private var seqCycles: UInt32 = 0

    /// Counter for throttling sequence gap log messages. Only logs every Nth gap
    /// to avoid flooding the console when UDP delivers many duplicates/reorders.
    private var gapLogCount: UInt32 = 0
    /// Number of duplicate packets silently dropped (for diagnostics).
    private var duplicateCount: UInt32 = 0

    /// Counter for throttling "FU-A without start" log messages.
    private var fuaNoStartLogCount: UInt32 = 0

    /// Maximum size of a reassembled FU-A NAL unit (2 MB). Buffers exceeding
    /// this are discarded to prevent unbounded memory growth on bad streams.
    private static let maxFuaBufferSize = 2 * 1024 * 1024

    /// Running RTP statistics forwarded to RtcpSender.
    private var stats = RtpStats(ssrc: 0, highestSeq: 0, packetCount: 0, octetCount: 0)

    // --- Diagnostic logging ---

    /// Wall-clock time of the last diagnostic log emission.
    private var lastDiagTime: Double = 0
    /// Packet count at the time of the last diagnostic log.
    private var lastDiagPacketCount: UInt32 = 0
    /// Octet count at the time of the last diagnostic log.
    private var lastDiagOctetCount: UInt32 = 0
    /// Number of transport reads performed since the last diagnostic log.
    private var readsSinceDiag: UInt32 = 0
    /// Number of RTCP packets received since the last diagnostic log.
    private var rtcpCountSinceDiag: UInt32 = 0
    /// Interval between diagnostic log emissions (seconds).
    private static let diagInterval: Double = 5.0

    private let log = OSLog(subsystem: "com.pandawatch.flutter_rtsps_plugin", category: "RtpDemuxer")

    // MARK: - Init

    /// - Parameter transport: A connected `RtspTransport` that has already
    ///   completed the RTSP handshake and is now in the streaming state.
    init(transport: RtspTransport) {
        self.transport = transport
    }

    // MARK: - Seed Data

    /// Prepends leftover bytes from the RTSP handshake so they are processed
    /// at the start of the read loop instead of being lost (Defect 1.12).
    ///
    /// Must be called BEFORE `start()`.
    func seedData(_ data: Data) {
        seedBuffer = data
    }

    /// Bytes seeded from the handshake lookahead, consumed at the start of the read loop.
    private var seedBuffer: Data?

    // MARK: - Lifecycle

    /// Launches a Swift `Task` that runs the read loop until `stop()` is called
    /// or the transport closes.
    func start() {
        runLock.lock()
        running = true
        runLock.unlock()
        Task { [weak self] in
            await self?.readLoop()
        }
    }

    /// Signals the read loop to exit after the current iteration.
    /// Clears reassembly state so a subsequent `start()` begins fresh (Req 2.22).
    func stop() {
        runLock.lock()
        running = false
        fuaBuffer = nil
        lastSeq = nil
        seqCycles = 0
        gapLogCount = 0
        duplicateCount = 0
        fuaNoStartLogCount = 0
        seedBuffer = nil
        runLock.unlock()
    }

    // MARK: - Read Loop

    /// Size of each transport read request. Large enough to consume an entire
    /// burst of RTP packets in one syscall, small enough to avoid excessive
    /// memory allocation. 64 KB matches the typical TCP receive window and
    /// ensures we drain the kernel buffer quickly on bursty encoders like the
    /// Bambu H2C.
    private static let readChunkSize = 65_536

    private func readLoop() async {
        // Accumulation buffer — we read whatever the kernel has available
        // (minimumLength: 1) and parse interleaved frames from this buffer.
        // This prevents blocking on exact-length reads when a bursty encoder
        // (e.g. Bambu H2C) splits the last RTP packet across TCP segments
        // with a multi-second gap between bursts.
        var buf = Data()

        // Consume any seed data from the handshake lookahead (Defect 1.12).
        runLock.lock()
        if let seed = seedBuffer, !seed.isEmpty {
            buf.append(seed)
        }
        seedBuffer = nil
        runLock.unlock()

        while true {
            runLock.lock()
            let isRunning = running
            runLock.unlock()
            guard isRunning else { break }

            do {
                // Parse as many complete interleaved frames as possible from buf.
                while let frame = Self.extractFrame(from: &buf) {
                    switch frame.channel {
                    case 0:
                        if drainOnly {
                            // UDP is active — discard TCP RTP data silently.
                            // We still need to read it to drain the kernel buffer.
                            break
                        }
                        processRtpPacket(frame.payload)
                    case 1:
                        rtcpCountSinceDiag += 1
                        onRtcpPacket?(frame.payload)
                    default:
                        os_log("RtpDemuxer: unknown channel %u, discarding",
                               log: log, type: .default, frame.channel)
                    }

                    // Re-check running flag between frames so stop() is responsive
                    // even when a large burst fills the buffer with many frames.
                    runLock.lock()
                    let stillRunning = running
                    runLock.unlock()
                    guard stillRunning else { return }
                }

                // Read whatever the kernel has available — minimumLength: 1
                // ensures we never block waiting for a specific byte count.
                let chunk = try await transport.receive(
                    minimumLength: 1,
                    maximumLength: Self.readChunkSize
                )
                buf.append(chunk)
                readsSinceDiag += 1

                // Periodic diagnostic logging
                let now = ProcessInfo.processInfo.systemUptime
                if lastDiagTime == 0 { lastDiagTime = now }
                if now - lastDiagTime >= RtpDemuxer.diagInterval {
                    let elapsed = now - lastDiagTime
                    let pktDelta = stats.packetCount - lastDiagPacketCount
                    let byteDelta = stats.octetCount - lastDiagOctetCount
                    let pps = elapsed > 0 ? Double(pktDelta) / elapsed : 0
                    let kbps = elapsed > 0 ? Double(byteDelta) * 8.0 / elapsed / 1000.0 : 0
                    os_log("RtpDemuxer: [diag] %.1fs: %u pkts (%.0f pps, %.0f kbps) seq=%u reads=%u rtcp=%u buf=%d dups=%u gaps=%u",
                           log: log, type: .info,
                           elapsed, pktDelta, pps, kbps,
                           stats.highestSeq, readsSinceDiag, rtcpCountSinceDiag, buf.count,
                           duplicateCount, gapLogCount)
                    lastDiagTime = now
                    lastDiagPacketCount = stats.packetCount
                    lastDiagOctetCount = stats.octetCount
                    readsSinceDiag = 0
                    rtcpCountSinceDiag = 0
                }

                // Compact: if we've consumed most of the buffer but there's a
                // large prefix of empty space from previous removeFirst calls,
                // Data's internal storage may hold onto it. Re-creating from a
                // slice forces a copy that releases the old backing store.
                // Only do this when the consumed prefix is large to avoid
                // unnecessary copies on every iteration.
                if buf.startIndex > 16_384 {
                    buf = Data(buf)
                }

            } catch {
                // Transport closed or errored — exit the loop cleanly
                os_log("RtpDemuxer: read loop exiting: %{public}@",
                       log: log, type: .info, error.localizedDescription)
                runLock.lock()
                running = false
                runLock.unlock()
            }
        }
    }

    // MARK: - Frame Extraction

    /// A parsed interleaved frame: channel + payload.
    private struct InterleavedFrame {
        let channel: UInt8
        let payload: Data
    }

    /// Attempts to extract one complete interleaved frame from the front of
    /// `buf`. Returns `nil` if the buffer doesn't contain a complete frame yet.
    ///
    /// Scans for the 0x24 ('$') magic byte, skipping any non-interleaved bytes
    /// (e.g. RTSP TEARDOWN response text that arrives during teardown).
    ///
    /// On success, the consumed bytes (header + payload) are removed from `buf`.
    /// On failure (incomplete), `buf` is left unchanged so the caller can read
    /// more data and retry.
    private static func extractFrame(from buf: inout Data) -> InterleavedFrame? {
        // Scan for the 0x24 magic byte, discarding any leading non-interleaved bytes.
        while !buf.isEmpty {
            let startIdx = buf.startIndex

            guard buf[startIdx] == 0x24 else {
                // Skip non-interleaved byte. 0x52 = 'R' from RTSP TEARDOWN
                // response — expected during teardown, not worth logging.
                buf.removeFirst()
                continue
            }

            // Need at least 4 bytes for the header: $ | channel | length(2)
            guard buf.count >= 4 else { return nil }

            let channel = buf[startIdx + 1]
            let length = Int(UInt16(buf[startIdx + 2]) << 8 | UInt16(buf[startIdx + 3]))

            // Zero-length frame — consume header and continue scanning
            if length == 0 {
                buf.removeFirst(4)
                continue
            }

            // Check if the full payload is available
            let totalFrameSize = 4 + length
            guard buf.count >= totalFrameSize else {
                // Incomplete frame — leave buf intact, caller will read more data
                return nil
            }

            // Extract payload and consume the frame from the buffer
            let payloadStart = startIdx + 4
            let payload = Data(buf[payloadStart ..< payloadStart + length])
            buf.removeFirst(totalFrameSize)

            return InterleavedFrame(channel: channel, payload: payload)
        }

        return nil
    }

    // MARK: - RTP Packet Processing

    /// Parses the RTP header, extracts the NAL unit payload, and handles FU-A
    /// reassembly. (Req 2.4, 2.5, 2.7)
    private func processRtpPacket(_ packet: Data) {
        guard packet.count >= 12 else {
            os_log("RtpDemuxer: RTP packet too short (%d bytes)", log: log, type: .error, packet.count)
            return
        }

        // Byte 0: V(2) P(1) X(1) CC(4)
        let byte0 = packet[0]
        let hasExtension = (byte0 & 0x10) != 0
        let csrcCount = Int(byte0 & 0x0F)

        // Byte 1: M(1) PT(7)
        let byte1 = packet[1]
        let markerBit = (byte1 & 0x80) != 0

        // Bytes 2-3: sequence number
        let seqNum = (UInt32(packet[2]) << 8) | UInt32(packet[3])

        // Bytes 8-11: SSRC
        let ssrc = (UInt32(packet[8]) << 24) | (UInt32(packet[9]) << 16)
                 | (UInt32(packet[10]) << 8)  |  UInt32(packet[11])

        // Payload offset: fixed 12-byte header + CSRC list
        var offset = 12 + csrcCount * 4

        // Skip RTP header extension if X bit is set
        if hasExtension {
            // Extension: 2-byte profile + 2-byte length (in 32-bit words)
            guard packet.count >= offset + 4 else { return }
            let extLen = Int((UInt16(packet[offset + 2]) << 8) | UInt16(packet[offset + 3]))
            offset += 4 + extLen * 4
        }

        guard offset < packet.count else {
            os_log("RtpDemuxer: RTP payload offset %d beyond packet length %d", log: log, type: .error, offset, packet.count)
            return
        }

        let payload = packet[offset...]

        // Update statistics
        stats.ssrc = ssrc

        // Detect 16-bit sequence number wraparound (Defect 1.28)
        if let last = lastSeq {
            let lastLow = last & 0xFFFF
            if seqNum < lastLow && (lastLow - seqNum) > 0x8000 {
                seqCycles += 1
            }
        }

        stats.highestSeq = (seqCycles << 16) | seqNum
        stats.packetCount += 1
        stats.octetCount += UInt32(payload.count)

        // Bytes 4-7: RTP timestamp
        let rtpTimestamp = (UInt32(packet[4]) << 24) | (UInt32(packet[5]) << 16)
                         | (UInt32(packet[6]) << 8)  |  UInt32(packet[7])
        stats.rtpTimestamp = rtpTimestamp
        stats.arrivalTime = ProcessInfo.processInfo.systemUptime

        onRtpStats?(stats)

        // Detect sequence number discontinuity during FU-A reassembly.
        //
        // UDP transport can deliver duplicate packets, minor reordering,
        // and small gaps from WiFi packet loss. Strategy:
        //   1. Duplicate (seqNum == lastSeq): silently drop.
        //   2. Late/reordered (seqNum < expected, small delta): drop packet,
        //      keep FU-A buffer intact.
        //   3. Small forward gap (1-3 packets): continue FU-A reassembly.
        //      VideoToolbox handles minor corruption better than a fully
        //      dropped frame (which causes cascading P-frame glitches).
        //   4. Large forward gap (4+ packets): discard FU-A buffer — too
        //      much data is missing for a usable frame.
        if let last = lastSeq {
            let expected = (last + 1) & 0xFFFF
            if seqNum == last {
                // Duplicate packet — skip entirely, don't update lastSeq or stats
                duplicateCount += 1
                return
            }
            if seqNum != expected {
                // Check if this is a late/reordered packet (arrived after we
                // already processed a higher seq). Use modular distance to
                // handle wraparound: if the forward distance is large (> half
                // the sequence space), the packet is actually behind us.
                let forwardDist = (seqNum &- expected) & 0xFFFF
                if forwardDist > 0x8000 {
                    // Late packet — behind our current position. Drop it but
                    // don't destroy the FU-A buffer.
                    return
                }
                // Forward gap — genuine discontinuity.
                gapLogCount += 1
                if fuaBuffer != nil {
                    if forwardDist <= 3 {
                        // Small gap: continue reassembly. The missing fragment(s)
                        // will cause minor corruption in this NAL unit but
                        // VideoToolbox can usually decode it. Much better than
                        // dropping the entire frame and causing cascading
                        // reference frame errors on subsequent P-frames.
                        if gapLogCount <= 5 || gapLogCount % 200 == 0 {
                            os_log("RtpDemuxer: small seq gap (%u → %u, missing %u), continuing FU-A [gaps=%u]",
                                   log: log, type: .default, last, seqNum, forwardDist, gapLogCount)
                        }
                    } else {
                        // Large gap: too much data missing, discard buffer.
                        if gapLogCount <= 5 || gapLogCount % 200 == 0 {
                            os_log("RtpDemuxer: large seq gap (%u → %u, missing %u), discarding FU-A [gaps=%u]",
                                   log: log, type: .default, last, seqNum, forwardDist, gapLogCount)
                        }
                        fuaBuffer = nil
                    }
                }
            }
        }
        lastSeq = seqNum

        // Dispatch NAL unit extraction
        extractNalUnit(from: Data(payload), markerBit: markerBit)
    }

    // MARK: - NAL Unit Extraction

    /// Extracts a NAL unit from the RTP payload, handling FU-A fragmentation
    /// and STAP-A aggregation.
    private func extractNalUnit(from payload: Data, markerBit: Bool) {
        guard !payload.isEmpty else { return }

        let nalType = payload[0] & 0x1F

        switch nalType {
        case 28:
            // FU-A fragmented NAL unit (Req 2.7)
            handleFuA(payload: payload, markerBit: markerBit)
        case 24:
            // STAP-A: multiple NAL units aggregated in one RTP packet (RFC 6184 §5.7.1)
            // Format: STAP-A header (1 byte) | [size (2 bytes) | NAL unit] ...
            // The marker bit applies to the last NAL unit in the packet.
            handleStapA(payload: payload, markerBit: markerBit)
        default:
            // Single NAL unit packet — forward directly
            onNalUnit?(payload, markerBit)
        }
    }

    // MARK: - STAP-A Aggregation

    /// Handles STAP-A (NAL type 24) packets which carry multiple NAL units
    /// concatenated with 2-byte size prefixes (RFC 6184 §5.7.1).
    ///
    /// The marker bit signals end-of-access-unit and is forwarded only with
    /// the last NAL unit in the packet.
    private func handleStapA(payload: Data, markerBit: Bool) {
        // Skip the 1-byte STAP-A header
        var offset = 1
        var nalUnits: [Data] = []

        while offset + 2 <= payload.count {
            let size = Int(UInt16(payload[offset]) << 8 | UInt16(payload[offset + 1]))
            offset += 2
            guard size > 0, offset + size <= payload.count else {
                os_log("RtpDemuxer: STAP-A malformed at offset %d (size=%d, remaining=%d)",
                       log: log, type: .error, offset, size, payload.count - offset)
                break
            }
            nalUnits.append(Data(payload[offset ..< offset + size]))
            offset += size
        }

        guard !nalUnits.isEmpty else { return }

        for (i, nal) in nalUnits.enumerated() {
            let isLast = i == nalUnits.index(before: nalUnits.endIndex)
            // Only set the marker bit on the last NAL unit — it signals
            // end-of-access-unit to the decoder's accumulation logic.
            onNalUnit?(nal, isLast && markerBit)
        }
    }

    // MARK: - UDP Packet Feed

    /// Processes a raw RTP packet received over UDP (no interleaved framing).
    /// Called by `UdpMediaTransport.onRtpPacket` when using UDP transport.
    func feedRtpPacket(_ packet: Data) {
        processRtpPacket(packet)
    }

    // MARK: - Testing Shims

    /// Exposes `processRtpPacket` for unit tests that construct raw RTP bytes.
    func processRtpPacketForTesting(_ packet: Data) {
        processRtpPacket(packet)
    }

    /// Exposes the channel-dispatch logic for unit tests.
    func dispatchPayloadForTesting(channel: UInt8, payload: Data) {
        switch channel {
        case 0:
            processRtpPacket(payload)
        case 1:
            onRtcpPacket?(payload)
        default:
            break
        }
    }

    // MARK: - FU-A Reassembly

    /// Handles FU-A (NAL type 28) fragmentation reassembly.
    ///
    /// FU indicator byte: forbidden_zero(1) NRI(2) type=28(5)
    /// FU header byte:    S(1) E(1) R(1) nal_type(5)
    private func handleFuA(payload: Data, markerBit: Bool) {
        guard payload.count >= 2 else {
            os_log("RtpDemuxer: FU-A packet too short", log: log, type: .error)
            return
        }

        let fuIndicator = payload[0]  // NRI bits live here
        let fuHeader = payload[1]
        let isStart = (fuHeader & 0x80) != 0
        let isEnd   = (fuHeader & 0x40) != 0
        let nalType = fuHeader & 0x1F

        // Fragment payload: everything after the 2-byte FU header
        let fragment = payload[2...]

        if isStart {
            // Reconstruct the NAL header: (FU_indicator & 0xE0) | nal_type
            let nalHeader = (fuIndicator & 0xE0) | nalType
            fuaBuffer = Data([nalHeader])
            fuaBuffer?.append(contentsOf: fragment)
        } else if var buf = fuaBuffer {
            buf.append(contentsOf: fragment)

            // Guard against unbounded accumulation on malformed/corrupt streams
            if buf.count > RtpDemuxer.maxFuaBufferSize {
                os_log("RtpDemuxer: FU-A buffer exceeded %d bytes, discarding",
                       log: log, type: .error, RtpDemuxer.maxFuaBufferSize)
                fuaBuffer = nil
                return
            }

            fuaBuffer = buf

            if isEnd {
                // Complete NAL unit assembled — forward it
                onNalUnit?(fuaBuffer!, markerBit)
                fuaBuffer = nil
            }
        } else {
            // Middle/end fragment arrived without a start — discard
            fuaNoStartLogCount += 1
            if fuaNoStartLogCount <= 3 || fuaNoStartLogCount % 100 == 0 {
                os_log("RtpDemuxer: FU-A fragment without start, discarding [count=%u]",
                       log: log, type: .default, fuaNoStartLogCount)
            }
        }
    }
}
