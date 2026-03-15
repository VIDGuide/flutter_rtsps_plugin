import Foundation
import Network

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

/// Wraps `NWConnection` to provide an async/await TLS TCP transport.
///
/// Self-signed certificates are accepted unconditionally via
/// `sec_protocol_options_set_verify_block`, which is required for
/// Bambu Lab printers that use self-signed TLS certificates (Req 1.7).
final class RtspTransport {

    // MARK: - Private state

    private var connection: NWConnection?
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
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
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
    }

    // MARK: - Send

    /// Sends raw bytes over the connection.
    ///
    /// Throws `RtspError.connectionFailed` on write error.
    func send(data: Data) async throws {
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
    }

    // MARK: - Private helpers

    /// Builds `NWParameters` with TLS configured to accept self-signed certificates.
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

        let parameters = NWParameters(tls: tlsOptions)
        return parameters
    }
}
