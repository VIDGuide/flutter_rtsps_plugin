import Flutter
import Foundation
import os.log

// MARK: - RtspStreamSession

/// Owns and coordinates all components for a single RTSP streaming session:
/// `RtspTransport`, `RtspStateMachine`, `RtpDemuxer`, `RtcpSender`,
/// `H264Decoder`, and `FlutterTextureOutput`.
///
/// Requirements: 9.3, 9.6, 10.1, 10.2, 10.3
final class RtspStreamSession: NSObject {

    // MARK: - Public

    let streamId: Int

    // MARK: - Private — init params

    private let url: String
    private let username: String
    private let password: String
    private let textureRegistry: FlutterTextureRegistry
    private let binaryMessenger: FlutterBinaryMessenger

    // MARK: - Private — components (created in start())

    private var transport: RtspTransport?
    private var stateMachine: RtspStateMachine?
    private var demuxer: RtpDemuxer?
    private var rtcpSender: RtcpSender?
    private var decoder: H264Decoder?
    private var textureOutput: FlutterTextureOutput?

    // MARK: - Private — event channel

    private var eventChannel: FlutterEventChannel?
    /// Protected by `stateQueue`.
    private var eventSink: FlutterEventSink?

    // MARK: - Private — state flags

    /// Serial queue protecting `stopped`, `firstFrameEmitted`, and `eventSink`.
    private let stateQueue = DispatchQueue(label: "com.pandawatch.flutter_rtsps_plugin.session.\(arc4random())")
    private var stopped = false
    private var firstFrameEmitted = false

    private let log = OSLog(subsystem: "com.pandawatch.flutter_rtsps_plugin", category: "RtspStreamSession")

    // MARK: - Init

    init(
        streamId: Int,
        url: String,
        username: String,
        password: String,
        textureRegistry: FlutterTextureRegistry,
        binaryMessenger: FlutterBinaryMessenger
    ) {
        self.streamId = streamId
        self.url = url
        self.username = username
        self.password = password
        self.textureRegistry = textureRegistry
        self.binaryMessenger = binaryMessenger
    }

    // MARK: - Start

    /// Connects the transport, runs the RTSP handshake, starts the demuxer and
    /// RTCP sender, and returns the Flutter texture ID.
    ///
    /// - Returns: The `textureId` (Int64 cast to Int) for use with `Texture` widget.
    /// - Throws: `RtspError` on connection, auth, or decoder failure.
    func start() async throws -> Int {
        // Register the event channel so Dart can subscribe before first frame
        let channelName = "flutter_rtsps_plugin/events/\(streamId)"
        let channel = FlutterEventChannel(name: channelName, binaryMessenger: binaryMessenger)
        channel.setStreamHandler(self)
        eventChannel = channel

        // Build transport + state machine
        let transport = RtspTransport()
        self.transport = transport

        guard let sm = try? RtspStateMachine(
            transport: transport,
            url: url,
            username: username,
            password: password
        ) else {
            throw RtspError.connectionFailed("Invalid RTSP URL: \(url)")
        }
        stateMachine = sm

        // Connect
        guard let parsed = URL(string: url), let host = parsed.host else {
            throw RtspError.connectionFailed("Invalid RTSP URL: \(url)")
        }
        let port = UInt16(parsed.port ?? 322)
        try await transport.connect(host: host, port: port)
        os_log("RtspStreamSession[%d]: transport connected", log: log, type: .info, streamId)

        // Run RTSP handshake
        let videoTrack = try await sm.runHandshake()
        os_log("RtspStreamSession[%d]: handshake complete", log: log, type: .info, streamId)

        // Create texture output (must happen before decoder so callback is wired)
        let textureOut = FlutterTextureOutput(textureRegistry: textureRegistry)
        self.textureOutput = textureOut

        // Create decoder
        let dec = H264Decoder(
            onPixelBuffer: { [weak self] pixelBuffer in
                self?.textureOutput?.onNewFrame(pixelBuffer)
                self?.onNewFrame()
            },
            onError: { [weak self] error in
                self?.handleError(error)
            }
        )
        self.decoder = dec

        // Initialize decoder from SDP SPS/PPS if available
        if let sps = videoTrack.sps, let pps = videoTrack.pps {
            try dec.initializeDecoder(sps: sps, pps: pps)
        }

        // Create RTCP sender
        let rtcp = RtcpSender(transport: transport) { [weak self] error in
            self?.handleError(error)
        }
        self.rtcpSender = rtcp

        // Create demuxer and wire callbacks
        let demux = RtpDemuxer(transport: transport)
        demux.onNalUnit = { [weak dec] nalUnit, isFrameComplete in
            dec?.feedNalUnit(nalUnit, isFrameComplete: isFrameComplete)
        }
        demux.onRtcpPacket = { _ in
            // RTCP packets from server — no action needed for RR sending
        }
        demux.onRtpStats = { [weak rtcp] stats in
            rtcp?.updateStats(stats)
        }
        self.demuxer = demux

        // Start streaming components
        demux.start()
        rtcp.start()

        os_log("RtspStreamSession[%d]: streaming started, textureId=%lld",
               log: log, type: .info, streamId, textureOut.textureId)

        return Int(textureOut.textureId)
    }

    // MARK: - Stop

    /// Tears down all components in order and emits `RtspStoppedEvent`.
    /// Completes within 2 seconds (enforced via task group timeout). (Req 9.3)
    func stop() async {
        let alreadyStopped: Bool = stateQueue.sync {
            if stopped { return true }
            stopped = true
            return false
        }
        guard !alreadyStopped else { return }

        os_log("RtspStreamSession[%d]: stopping", log: log, type: .info, streamId)

        // Race the teardown against a 2-second deadline (Req 9.3)
        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                await self?.performStop()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                // Timeout reached — cancel the other task
            }
            // Take whichever finishes first
            _ = try? await group.next()
            group.cancelAll()
        }

        emitEvent(["type": "stopped"])
        os_log("RtspStreamSession[%d]: stopped", log: log, type: .info, streamId)
    }

    // MARK: - Private — teardown sequence

    private func performStop() async {
        // 1. Teardown RTSP (sends TEARDOWN + closes transport)
        await stateMachine?.teardown()

        // 2. Stop RTCP timer
        rtcpSender?.stop()

        // 3. Stop demuxer read loop
        demuxer?.stop()

        // 4. Stop decoder (invalidates VTDecompressionSession)
        decoder?.stop()

        // 5. Unregister texture
        textureOutput?.stop()
    }

    // MARK: - Private — first frame

    /// Called on every decoded frame; emits `RtspPlayingEvent` exactly once,
    /// then emits a `frame` timestamp event for every subsequent frame.
    private func onNewFrame() {
        stateQueue.async { [weak self] in
            guard let self, !self.stopped else { return }
            if !self.firstFrameEmitted {
                self.firstFrameEmitted = true
                self.emitEvent(["type": "playing", "textureId": Int(self.textureOutput?.textureId ?? 0)])
            } else {
                self.emitEvent(["type": "frame", "ts": Int(Date().timeIntervalSince1970 * 1000)])
            }
        }
    }

    // MARK: - Private — error handling

    /// Shared error handler for `RtcpSender.onError` and `H264Decoder.onError`.
    /// Emits an error event then calls `stop()` (which emits stopped). (Req 9.6, 10.3)
    private func handleError(_ error: Error) {
        let alreadyStopped: Bool = stateQueue.sync { stopped }
        guard !alreadyStopped else { return }

        os_log("RtspStreamSession[%d]: error — %{public}@",
               log: log, type: .error, streamId, error.localizedDescription)

        let (code, message) = errorCodeAndMessage(for: error)

        // Emit error first, then tear down (which emits stopped)
        emitEvent(["type": "error", "code": code, "message": message])

        Task { [weak self] in
            await self?.stop()
        }
    }

    // MARK: - Private — event emission

    private func emitEvent(_ event: [String: Any]) {
        stateQueue.async { [weak self] in
            guard let sink = self?.eventSink else { return }
            DispatchQueue.main.async {
                sink(event)
            }
        }
    }

    // MARK: - Private — error mapping

    /// Maps `RtspError` cases to the string codes expected by the Dart side.
    private func errorCodeAndMessage(for error: Error) -> (String, String) {
        if let rtspError = error as? RtspError {
            switch rtspError {
            case .connectionFailed(let msg):
                return ("connectionFailed", msg)
            case .authenticationFailed:
                return ("authenticationFailed", "Authentication failed")
            case .timeout:
                return ("timeout", "Request timed out")
            case .noVideoTrack:
                return ("noVideoTrack", "No video track found in SDP")
            case .decoderError:
                return ("decoderError", "H.264 decoder error")
            case .tooManyStreams:
                return ("tooManyStreams", "Too many concurrent streams")
            }
        }
        return ("connectionFailed", error.localizedDescription)
    }
}

// MARK: - FlutterStreamHandler

extension RtspStreamSession: FlutterStreamHandler {

    /// Called when Dart subscribes to the event channel.
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        stateQueue.async { [weak self] in
            self?.eventSink = events
        }
        return nil
    }

    /// Called when Dart cancels the event channel subscription.
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        stateQueue.async { [weak self] in
            self?.eventSink = nil
        }
        return nil
    }
}
