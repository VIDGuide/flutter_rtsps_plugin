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

        defer {
            rtcpSender?.stop()
            demuxer?.stop()
            decoder?.stop()
            transport.close()
            os_log("SnapshotCapture: resources released", log: log, type: .info)
        }

        try await transport.connect(host: host, port: port)
        os_log("SnapshotCapture: transport connected to %{public}@:%u", log: log, type: .info, host, port)

        // Run RTSP handshake (Req 6.1)
        let handshakeResult = try await stateMachine.runHandshake()
        let videoTrack = handshakeResult.videoTrack
        os_log("SnapshotCapture: handshake complete", log: log, type: .info)

        // Create RTCP sender to keep the server streaming during snapshot
        // capture (Defect 1.14, Req 2.14). Without this the Bambu printer
        // stops sending after ~1.8 s of buffered frames.
        let rtcp = RtcpSender(transport: transport) { error in
            // Snapshot is short-lived; RTCP write errors are non-fatal here.
            os_log("SnapshotCapture: RTCP send error — %{public}@",
                   type: .error, error.localizedDescription)
        }
        rtcpSender = rtcp

        // Adjust RTCP interval when the server advertises a session timeout
        // so keepalives fire well within the expiry window (Req 2.14).
        let rtcpInterval: TimeInterval
        if let timeout = handshakeResult.serverTimeout, timeout > 0 {
            rtcpInterval = min(1.0, Double(timeout) / 3.0)
        } else {
            rtcpInterval = 1.0
        }
        rtcp.start(interval: rtcpInterval)

        // Race: first decoded frame vs. timeout (Req 6.3)
        let pixelBuffer = try await withThrowingTaskGroup(of: CVPixelBuffer.self) { group in

            // Task A: wait for the first decoded CVPixelBuffer via a continuation
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CVPixelBuffer, Error>) in
                    var resumed = false

                    let dec = H264Decoder(
                        onPixelBuffer: { pixelBuffer in
                            guard !resumed else { return }
                            resumed = true
                            continuation.resume(returning: pixelBuffer)
                        },
                        onError: { error in
                            guard !resumed else { return }
                            resumed = true
                            continuation.resume(throwing: error)
                        }
                    )
                    decoder = dec

                    // Initialize decoder from SDP SPS/PPS if available
                    if let sps = videoTrack.sps, let pps = videoTrack.pps {
                        do {
                            try dec.initializeDecoder(sps: sps, pps: pps)
                        } catch {
                            guard !resumed else { return }
                            resumed = true
                            continuation.resume(throwing: error)
                            return
                        }
                    }

                    // Wire demuxer → decoder
                    let dmx = RtpDemuxer(transport: transport)
                    dmx.onNalUnit = { [weak dec] nalUnit, isFrameComplete in
                        dec?.feedNalUnit(nalUnit, isFrameComplete: isFrameComplete)
                    }
                    // Wire demuxer stats → RTCP sender (Defect 1.14, Req 2.14)
                    dmx.onRtpStats = { [weak rtcp] stats in
                        rtcp?.updateStats(stats)
                    }
                    demuxer = dmx

                    // Seed any leftover bytes from the handshake (Defect 1.12)
                    if let leftover = handshakeResult.remainingData {
                        dmx.seedData(leftover)
                    }

                    dmx.start()
                }
            }

            // Task B: timeout (Req 6.3)
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(clampedTimeout) * 1_000_000_000)
                throw RtspError.timeout
            }

            // Whichever task finishes first wins; cancel the other
            let result = try await group.next()!
            group.cancelAll()
            return result
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
