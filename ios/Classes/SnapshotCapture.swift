import CoreImage
import CoreVideo
import Foundation
import os.log

// MARK: - SnapshotCapture

/// Connects to an `rtsps://` stream, decodes the first complete video frame,
/// encodes it as JPEG, and disconnects — all in a single async call.
///
/// Create a new instance per snapshot; instances are not reusable.
///
/// Requirements: 6.1, 6.2, 6.3, 6.4, 6.5
final class SnapshotCapture {

    private let log = OSLog(subsystem: "com.pandawatch.flutter_rtsps_plugin", category: "SnapshotCapture")

    /// Shared CIContext — expensive to create, reused across encode calls.
    private static let ciContext = CIContext()

    // MARK: - Frame Bridge

    /// Thread-safe one-shot bridge from the VideoToolbox callback world to
    /// Swift Concurrency. Stores a `CheckedContinuation` and resumes it
    /// exactly once, regardless of how many times `deliver` or `fail` are
    /// called from arbitrary threads.
    ///
    /// The instance is heap-allocated and reference-counted, so it outlives
    /// the `withCheckedThrowingContinuation` scope — safe to capture in
    /// `H264Decoder` callbacks that fire asynchronously after the continuation
    /// has already been resumed.
    private final class FrameBridge: @unchecked Sendable {
        private var continuation: CheckedContinuation<CVPixelBuffer, Error>?
        private let lock = NSLock()

        func setContinuation(_ c: CheckedContinuation<CVPixelBuffer, Error>) {
            lock.lock(); defer { lock.unlock() }
            continuation = c
        }

        func deliver(_ pixelBuffer: CVPixelBuffer) {
            lock.lock()
            guard let c = continuation else { lock.unlock(); return }
            continuation = nil
            lock.unlock()
            c.resume(returning: pixelBuffer)
        }

        func fail(_ error: Error) {
            lock.lock()
            guard let c = continuation else { lock.unlock(); return }
            continuation = nil
            lock.unlock()
            c.resume(throwing: error)
        }
    }

    /// `Sendable` wrapper for `CVPixelBuffer` which CoreVideo marks as
    /// non-Sendable. Safe here because the pixel buffer is only read after
    /// the task group completes (no concurrent mutation).
    private struct SendablePixelBuffer: @unchecked Sendable {
        let buffer: CVPixelBuffer
    }

    // MARK: - Public API

    /// Connects, decodes the first frame, encodes it as JPEG, and disconnects.
    ///
    /// - Parameters:
    ///   - url: Full `rtsps://` URL of the stream.
    ///   - username: Credential username (may be empty).
    ///   - password: Credential password (may be empty).
    ///   - timeoutSeconds: Maximum seconds to wait for the first frame (1–60). (Req 6.4)
    /// - Returns: JPEG-encoded `Data` of the first decoded frame. (Req 6.2)
    /// - Throws: `RtspError.timeout` if no frame arrives within `timeoutSeconds`. (Req 6.3)
    ///           Other `RtspError` variants on connection / auth / decode failure.
    func capture(
        url: String,
        username: String,
        password: String,
        timeoutSeconds: Int
    ) async throws -> Data {
        // Clamp timeout to the documented 1–60 range (Req 6.4)
        let clampedTimeout = max(1, min(60, timeoutSeconds))

        // Build components — no FlutterTextureOutput needed for snapshot
        let transport = RtspTransport()

        guard let stateMachine = try? RtspStateMachine(
            transport: transport,
            url: url,
            username: username,
            password: password
        ) else {
            throw RtspError.connectionFailed("Invalid RTSP URL: \(url)")
        }

        // Connect transport
        guard let parsed = URL(string: url), let host = parsed.host else {
            throw RtspError.connectionFailed("Invalid RTSP URL: \(url)")
        }
        let port = UInt16(parsed.port ?? 322)

        // Always clean up on exit (Req 6.5)
        var demuxer: RtpDemuxer? = nil
        var decoder: H264Decoder? = nil
        var rtcpSender: RtcpSender? = nil
        var udpTransport: UdpMediaTransport? = nil

        defer {
            udpTransport?.stop()
            rtcpSender?.stop()
            demuxer?.stop()
            decoder?.stopSync()
            transport.close()
            os_log("SnapshotCapture: resources released", log: log, type: .info)
        }

        try await transport.connect(host: host, port: port)
        os_log("SnapshotCapture: transport connected to %{public}@:%u", log: log, type: .info, host, port)

        // Run RTSP handshake (Req 6.1) — use TCP interleaved for snapshots.
        // Snapshots only need a single decoded frame, so TCP's reliability
        // matters more than UDP's lower latency. The H2C printer exhibits
        // severe UDP packet loss (2-4s bursts then 5-7s stalls) that
        // prevents the decoder from ever assembling a complete frame.
        // Live stream sessions still use UDP for sustained playback.
        let handshakeResult = try await stateMachine.runHandshake(preferUdp: false)
        let videoTrack = handshakeResult.videoTrack
        os_log("SnapshotCapture: handshake complete", log: log, type: .info)

        // Create RTCP sender to keep the server streaming during snapshot
        // capture (Defect 1.14, Req 2.14). Without this the Bambu printer
        // stops sending after ~1.8 s of buffered frames.
        let rtcp = RtcpSender(transport: transport) { error in
            os_log("SnapshotCapture: RTCP send error — %{public}@",
                   type: .error, error.localizedDescription)
        }
        rtcpSender = rtcp

        let rtcpInterval: TimeInterval
        if let timeout = handshakeResult.serverTimeout, timeout > 0 {
            rtcpInterval = min(1.0, Double(timeout) / 3.0)
        } else {
            rtcpInterval = 1.0
        }

        // Race: first decoded frame vs. timeout (Req 6.3)
        //
        // FrameBridge is a heap-allocated, lock-protected one-shot bridge.
        // It holds the CheckedContinuation as an optional and nulls it after
        // the first resume, so late VideoToolbox callbacks are safely ignored
        // without accessing freed memory.
        let bridge = FrameBridge()

        let dec = H264Decoder(
            onPixelBuffer: { [bridge] pixelBuffer in
                bridge.deliver(pixelBuffer)
            },
            onError: { [bridge] error in
                bridge.fail(error)
            }
        )
        decoder = dec

        if let sps = videoTrack.sps, let pps = videoTrack.pps {
            try dec.initializeDecoder(sps: sps, pps: pps)
        }

        let dmx = RtpDemuxer(transport: transport)
        dmx.onNalUnit = { [weak dec] nalUnit, isFrameComplete in
            dec?.feedNalUnit(nalUnit, isFrameComplete: isFrameComplete)
        }
        dmx.onRtpStats = { [weak rtcp] stats in
            rtcp?.updateStats(stats)
        }
        demuxer = dmx

        // Wire up UDP transport if the server accepted it
        if let udpInfo = handshakeResult.udpTransport {
            let udp = UdpMediaTransport(info: udpInfo)
            udp.onRtpPacket = { [weak dmx] packet in
                dmx?.feedRtpPacket(packet)
            }
            udp.onRtcpPacket = { [weak rtcp] data in
                rtcp?.processRtcpPacket(data)
            }
            rtcp.udpSendHandler = { [weak udp] data in
                udp?.sendRtcp(data)
            }
            try udp.start()
            udpTransport = udp
            os_log("SnapshotCapture: using UDP transport (server %{public}@:%u/%u)",
                   log: log, type: .info,
                   udpInfo.serverHost, udpInfo.serverRtpPort, udpInfo.serverRtcpPort)
        }

        // Always start the TCP demuxer read loop — even with UDP active,
        // we need to drain any data LIVE555 sends on the TCP channel to
        // prevent the server's send buffer from filling up and blocking.
        // In UDP mode, the demuxer discards RTP data (drainOnly) and only
        // forwards RTCP.
        if handshakeResult.udpTransport != nil {
            dmx.drainOnly = true
        }
        if let leftover = handshakeResult.remainingData {
            dmx.seedData(leftover)
        }
        dmx.start()

        rtcp.start(interval: rtcpInterval)

        // Await first frame with timeout
        let pixelBuffer: CVPixelBuffer = try await withThrowingTaskGroup(of: SendablePixelBuffer.self) { group in
            group.addTask {
                let buf = try await withCheckedThrowingContinuation { continuation in
                    bridge.setContinuation(continuation)
                }
                return SendablePixelBuffer(buffer: buf)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(clampedTimeout) * 1_000_000_000)
                throw RtspError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            // Nil out the continuation in the bridge so any late callbacks
            // from VideoToolbox are silently dropped.
            bridge.fail(RtspError.connectionFailed("cancelled"))
            return result.buffer
        }

        // Encode CVPixelBuffer → JPEG (Req 6.2)
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let jpegData = SnapshotCapture.ciContext.jpegRepresentation(of: ciImage, colorSpace: colorSpace) else {
            throw RtspError.decoderError
        }

        os_log("SnapshotCapture: JPEG encoded, %d bytes", log: log, type: .info, jpegData.count)
        return jpegData
    }
}
