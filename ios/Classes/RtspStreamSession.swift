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
    private var udpMediaTransport: UdpMediaTransport?

    // MARK: - Private — event channel

    private var eventChannel: FlutterEventChannel?
    /// Protected by `stateQueue`.
    private var eventSink: FlutterEventSink?

    // MARK: - Private — state flags

    /// Serial queue protecting `stopped`, `started`, `firstFrameEmitted`, and `eventSink`.
    private let stateQueue = DispatchQueue(label: "com.pandawatch.flutter_rtsps_plugin.session.\(arc4random())")
    private var stopped = false
    private var started = false
    private var firstFrameEmitted = false

    /// The Task running `start()`. Cancelled by `RtspStreamManager.stopStream`
    /// to abort an in-flight connection attempt (Defect 1.7).
    var startTask: Task<Int, Error>?

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
        // Guard against duplicate start (Defect 1.2)
        let alreadyStarted: Bool = stateQueue.sync {
            if started { return true }
            started = true
            return false
        }
        guard !alreadyStarted else {
            throw RtspError.connectionFailed("Session already started")
        }

        // Register the event channel so Dart can subscribe before first frame.
        // FlutterEventChannel.setStreamHandler must be called on the main thread.
        let channelName = "flutter_rtsps_plugin/events/\(streamId)"
        await MainActor.run {
            let channel = FlutterEventChannel(name: channelName, binaryMessenger: binaryMessenger)
            channel.setStreamHandler(self)
            eventChannel = channel
        }

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
        let defaultPort = parsed.scheme?.lowercased() == "rtsps" ? 322 : 554
        let port = UInt16(parsed.port ?? defaultPort)
        try await transport.connect(host: host, port: port)
        os_log("RtspStreamSession[%d]: transport connected", log: log, type: .info, streamId)

        // Check for cancellation after connect (Defect 1.7)
        try Task.checkCancellation()

        // Run RTSP handshake
        let handshakeResult = try await sm.runHandshake()
        let videoTrack = handshakeResult.videoTrack
        os_log("RtspStreamSession[%d]: handshake complete", log: log, type: .info, streamId)

        // Check for cancellation after handshake (Defect 1.7)
        try Task.checkCancellation()

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
        demux.onRtcpPacket = { [weak rtcp] data in
            rtcp?.processRtcpPacket(data)
        }
        demux.onRtpStats = { [weak rtcp] stats in
            rtcp?.updateStats(stats)
        }
        self.demuxer = demux

        // Check if UDP transport was negotiated
        if let udpInfo = handshakeResult.udpTransport {
            // UDP path: receive RTP/RTCP over UDP sockets instead of TCP interleaved.
            // This bypasses TCP/TLS backpressure that causes stream stalling on
            // some Bambu printer firmware (notably H2C).
            let udpTransport = UdpMediaTransport(info: udpInfo)
            udpTransport.onRtpPacket = { [weak demux] packet in
                demux?.feedRtpPacket(packet)
            }
            udpTransport.onRtcpPacket = { [weak rtcp] data in
                rtcp?.processRtcpPacket(data)
            }
            udpTransport.onError = { [weak self] error in
                self?.handleError(error)
            }
            // Wire RTCP sender to use UDP instead of TCP interleaved
            rtcp.udpSendHandler = { [weak udpTransport] data in
                udpTransport?.sendRtcp(data)
            }
            try udpTransport.start()
            self.udpMediaTransport = udpTransport
            os_log("RtspStreamSession[%d]: using UDP transport (server %{public}@:%u/%u)",
                   log: log, type: .info, streamId,
                   udpInfo.serverHost, udpInfo.serverRtpPort, udpInfo.serverRtcpPort)

            // Start a TCP drain loop to prevent the RTSP signaling connection's
            // receive buffer from filling up. LIVE555 may send RTCP Sender Reports
            // (or even interleaved RTP) on the TCP channel regardless of the
            // negotiated UDP transport. If nobody reads from the TCP socket, the
            // kernel's receive window closes, the server's send buffer fills, and
            // the server blocks — stalling the encoder for ALL transports including
            // UDP. The demuxer's read loop handles this: it reads and discards
            // TCP interleaved RTP data (drainOnly mode) while still forwarding
            // RTCP to the sender. Video data comes exclusively from UDP.
            demux.drainOnly = true
            if let leftover = handshakeResult.remainingData {
                demux.seedData(leftover)
            }
            demux.start()
        } else {
            // TCP interleaved path: seed leftover bytes and start demuxer read loop
            if let leftover = handshakeResult.remainingData {
                demux.seedData(leftover)
            }
            demux.start()
        }

        // Start RTCP sender (works for both UDP and TCP paths)
        rtcp.start()

        os_log("RtspStreamSession[%d]: streaming started, textureId=%lld",
               log: log, type: .info, streamId, textureOut.textureId)

        return Int(textureOut.textureId)
    }

    // MARK: - Frame capture

    /// Returns JPEG data from the most recently decoded frame, or `nil` if no
    /// frame has been received yet.
    func captureFrame() -> Data? {
        return textureOutput?.captureJpeg()
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

        // Race the graceful teardown against a 2-second deadline (Req 9.3).
        // We capture the transport reference before the race so we can force-close
        // it if the timeout fires before performStop() finishes — ensuring the
        // NWConnection is always released even if TEARDOWN hangs.
        let capturedTransport = transport
        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.performStop()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                // Timeout reached — force-close the transport so the other task unblocks
                capturedTransport?.close()
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

        // 3b. Stop UDP media transport if active
        udpMediaTransport?.stop()

        // 4. Stop decoder (invalidates VTDecompressionSession)
        decoder?.stop()

        // 5. Unregister texture
        textureOutput?.stop()

        // 6. Nil component references so late-firing callbacks find nil (Defect 1.20)
        transport = nil
        stateMachine = nil
        demuxer = nil
        rtcpSender = nil
        decoder = nil
        textureOutput = nil
        udpMediaTransport = nil

        // 7. Clean up event channel (Defect 1.21)
        await MainActor.run {
            eventChannel?.setStreamHandler(nil)
            eventChannel = nil
        }
    }

    // MARK: - Private — first frame

    /// Called on every decoded frame; emits `RtspPlayingEvent` exactly once
    /// (which also carries the first frame timestamp), then emits a `frame`
    /// timestamp event for every subsequent frame.
    private func onNewFrame() {
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        stateQueue.async { [weak self] in
            guard let self, !self.stopped else { return }
            if !self.firstFrameEmitted {
                self.firstFrameEmitted = true
                // Include the timestamp so FpsOverlay counts the very first frame.
                self.emitEvent([
                    "type": "playing",
                    "textureId": Int(self.textureOutput?.textureId ?? 0),
                    "ts": ts
                ])
            } else {
                self.emitEvent(["type": "frame", "ts": ts])
            }
        }
    }

    // MARK: - Private — error handling

    /// Shared error handler for `RtcpSender.onError` and `H264Decoder.onError`.
    /// Emits an error event then calls `stop()` (which emits stopped). (Req 9.6, 10.3)
    ///
    /// Atomically checks-and-sets `stopped` within a single `stateQueue.sync`
    /// block, then calls `performStop()` directly — no separate Task dispatch
    /// (Defect 1.1: prevents double-teardown race).
    private func handleError(_ error: Error) {
        let alreadyStopped: Bool = stateQueue.sync {
            if stopped { return true }
            stopped = true
            return false
        }
        guard !alreadyStopped else { return }

        os_log("RtspStreamSession[%d]: error — %{public}@",
               log: log, type: .error, streamId, error.localizedDescription)

        let (code, message) = errorCodeAndMessage(for: error)

        // Emit error first, then tear down (which emits stopped)
        emitEvent(["type": "error", "code": code, "message": message])

        Task { [weak self] in
            guard let self else { return }
            // stopped is already set — go straight to teardown + emit stopped
            await self.performStop()
            self.emitEvent(["type": "stopped"])
            os_log("RtspStreamSession[%d]: stopped (from handleError)", log: self.log, type: .info, self.streamId)
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
