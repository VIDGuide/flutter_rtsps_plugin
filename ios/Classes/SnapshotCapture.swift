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

        defer {
            demuxer?.stop()
            decoder?.stop()
            transport.close()
            os_log("SnapshotCapture: resources released", log: log, type: .info)
        }

        try await transport.connect(host: host, port: port)
        os_log("SnapshotCapture: transport connected to %{public}@:%u", log: log, type: .info, host, port)

        // Run RTSP handshake (Req 6.1)
        let videoTrack = try await stateMachine.runHandshake()
        os_log("SnapshotCapture: handshake complete", log: log, type: .info)

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
                    demuxer = dmx
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
        let context = CIContext()

        guard let jpegData = context.jpegRepresentation(of: ciImage, colorSpace: colorSpace) else {
            throw RtspError.decoderError
        }

        os_log("SnapshotCapture: JPEG encoded, %d bytes", log: log, type: .info, jpegData.count)
        return jpegData
    }
}
