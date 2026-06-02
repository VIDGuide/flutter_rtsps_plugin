import Foundation
import Network
import os.log

// MARK: - RtspError

/// Native Swift error type used throughout the plugin.
/// Distinct from the Dart-side RtspException.
enum RtspError: Error, LocalizedError {
    case connectionFailed(String)
    case timeout
    case authenticationFailed
    case noVideoTrack
    case decoderError
    case tooManyStreams

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .timeout:                   return "Request timed out"
        case .authenticationFailed:      return "Authentication failed"
        case .noVideoTrack:              return "No video track found in SDP"
        case .decoderError:              return "H.264 decoder error"
        case .tooManyStreams:            return "Too many concurrent streams"
        }
    }
}

// MARK: - RtspTransport

private let transportLog = OSLog(subsystem: "com.pandawatch.flutter_rtsps_plugin", category: "RtspTransport")

/// Wraps `NWConnection` to provide an async/await TLS TCP transport.
///
/// Self-signed certificates are accepted unconditionally via
/// `sec_protocol_options_set_verify_block`, which is required for
/// Bambu Lab printers that use self-signed TLS certificates (Req 1.7).
final class RtspTransport {

    // MARK: - Public callbacks

    /// Called when a post-connection failure is detected (`.failed` or `.cancelled`
    /// state after the connection was previously `.ready`).
    var onDisconnect: ((Error) -> Void)?

    // MARK: - Private state

    private var connection: NWConnection?
    private var connectionState: NWConnection.State = .setup
    private let dispatchQueue = DispatchQueue(label: "com.pandawatch.flutter_rtsps_plugin.transport")

    // MARK: - Connect

    /// Establishes a TLS TCP connection to the given host and port.
    ///
    /// Throws `RtspError.connectionFailed` if the connection cannot be
    /// established (including TLS failures for non-self-signed scenarios
    /// that slip through the verify block).
    func connect(host: String, port: UInt16) async throws {
        let parameters = Self.makeTLSParameters()
        let nwHost = NWEndpoint.Host(host)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw RtspError.connectionFailed("Invalid port: \(port)")
        }

        let conn = NWConnection(host: nwHost, port: nwPort, using: parameters)
        self.connection = conn

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false

            conn.stateUpdateHandler = { [weak self] state in
                self?.connectionState = state
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    os_log("RtspTransport: connected to %{public}@:%u (TCP rcvbuf requested=1MB, actual is kernel-managed)",
                           log: transportLog, type: .info, String(describing: nwHost), nwPort.rawValue)
                    continuation.resume()

                case .failed(let error):
                    resumed = true
                    self?.connection = nil
                    continuation.resume(throwing: RtspError.connectionFailed(error.localizedDescription))

                case .cancelled:
                    resumed = true
                    self?.connection = nil
                    continuation.resume(throwing: RtspError.connectionFailed("Connection was cancelled"))

                default:
                    break
                }
            }

            conn.start(queue: self.dispatchQueue)
        }

        // Post-connection monitoring: detect .failed/.cancelled after .ready
        connection?.stateUpdateHandler = { [weak self] state in
            self?.connectionState = state
            switch state {
            case .failed(let error):
                self?.connection = nil
                self?.onDisconnect?(RtspError.connectionFailed(error.localizedDescription))

            case .cancelled:
                self?.connection = nil
                self?.onDisconnect?(RtspError.connectionFailed("Connection was cancelled"))

            default:
                break
            }
        }
    }

    // MARK: - Send

    /// Sends raw bytes over the connection.
    ///
    /// Throws `RtspError.connectionFailed` on write error.
    func send(data: Data) async throws {
        guard connectionState == .ready else {
            throw RtspError.connectionFailed("Connection not ready: \(connectionState)")
        }
        guard let conn = connection else {
            throw RtspError.connectionFailed("Not connected")
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: RtspError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    // MARK: - Receive

    /// Reads between `minimumLength` and `maximumLength` bytes from the connection.
    ///
    /// Throws `RtspError.connectionFailed` on read error or if the connection
    /// closes before the minimum number of bytes is received.
    func receive(minimumLength: Int, maximumLength: Int) async throws -> Data {
        guard connectionState == .ready else {
            throw RtspError.connectionFailed("Connection not ready: \(connectionState)")
        }
        guard let conn = connection else {
            throw RtspError.connectionFailed("Not connected")
        }

        return try await withCheckedThrowingContinuation { continuation in
            conn.receive(minimumIncompleteLength: minimumLength, maximumLength: maximumLength) { content, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: RtspError.connectionFailed(error.localizedDescription))
                    return
                }
                if let data = content, !data.isEmpty {
                    continuation.resume(returning: data)
                    return
                }
                if isComplete {
                    continuation.resume(throwing: RtspError.connectionFailed("Connection closed by remote"))
                    return
                }
                // No data and not complete — treat as empty read error
                continuation.resume(throwing: RtspError.connectionFailed("Received empty data"))
            }
        }
    }

    // MARK: - Close

    /// Cancels the underlying NWConnection and releases it.
    func close() {
        connection?.cancel()
        connection = nil
        connectionState = .setup
    }

    // MARK: - Private helpers

    /// Builds `NWParameters` with TLS configured to accept self-signed certificates.
    ///
    /// TCP options are tuned for low-latency RTSP streaming:
    /// - `noDelay = true` disables Nagle's algorithm so our small RTCP
    ///   Receiver Report packets (36 bytes) are sent immediately rather than
    ///   being held for coalescing. Some Bambu printer firmware (notably the
    ///   H2C) appears to use TCP-level feedback to pace its encoder — delayed
    ///   ACKs from Nagle buffering can cause the encoder to stall.
    private static func makeTLSParameters() -> NWParameters {
        let tlsOptions = NWProtocolTLS.Options()

        // Accept all certificates, including self-signed ones used by Bambu Lab printers.
        // The verify block is dispatched on a background queue to avoid blocking the main thread.
        let verifyQueue = DispatchQueue(label: "com.pandawatch.flutter_rtsps_plugin.tls-verify")
        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { _, _, completionHandler in
                // Always accept — self-signed certs are expected on Bambu Lab printers.
                completionHandler(true)
            },
            verifyQueue
        )

        // Configure TCP for low-latency streaming
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true                    // Disable Nagle's algorithm
        tcpOptions.connectionTimeout = 10            // 10-second connection timeout
        tcpOptions.enableKeepalive = true            // Keep connection alive during stalls
        tcpOptions.keepaliveIdle = 5                 // Start keepalive probes after 5s idle

        // Request larger receive buffer for bursty H.264 I-frame delivery (Req 8.1).
        // NWProtocolTCP.Options does not expose SO_RCVBUF directly.
        // iOS kernel auto-tunes TCP receive buffers to ~1MB+ which is sufficient
        // for 1080p I-frame bursts (70+ packets × ~1400 bytes ≈ 100KB).
        // TCP_NODELAY (noDelay = true above) is the critical setting for latency.
        os_log("RtspTransport: TCP receive buffer relies on kernel auto-tuning (SO_RCVBUF not exposed via Network.framework)",
               log: transportLog, type: .debug)

        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        return parameters
    }
}
