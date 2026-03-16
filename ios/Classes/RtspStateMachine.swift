import CommonCrypto
import Foundation

// MARK: - RtspStateMachine

/// Drives the RTSP OPTIONS → DESCRIBE → SETUP → PLAY handshake over an
/// already-connected `RtspTransport`.
///
/// Responsibilities:
/// - Build and send RTSP requests with incrementing CSeq values.
/// - Parse RTSP responses (status line, headers, optional body).
/// - Retry once with Digest authentication on 401 responses.
/// - Enforce a 10-second per-request timeout (Req 1.8).
/// - Return the parsed `SdpVideoTrack` on PLAY success (Req 1.5).
/// - Send TEARDOWN and close the transport on `teardown()` (Req 1.9).
final class RtspStateMachine {

    // MARK: - Private state

    private let transport: RtspTransport
    private let url: String
    private let username: String
    private let password: String

    /// Parsed URL components, populated in `init`.
    private let parsedURL: URL
    private let host: String
    private let port: Int
    private let path: String

    /// Monotonically increasing CSeq counter.
    private var cseq: Int = 1

    /// Session ID returned by the server in the SETUP response.
    private var sessionId: String?

    // MARK: - Init

    /// - Parameters:
    ///   - transport: A connected (or ready-to-connect) `RtspTransport`.
    ///   - url: The full `rtsps://` URL of the stream.
    ///   - username: Credential username (may be empty).
    ///   - password: Credential password (may be empty).
    init(transport: RtspTransport, url: String, username: String, password: String) throws {
        guard let parsed = URL(string: url),
              let host = parsed.host else {
            throw RtspError.connectionFailed("Invalid RTSP URL: \(url)")
        }
        self.transport = transport
        self.url = url
        self.username = username
        self.password = password
        self.parsedURL = parsed
        self.host = host
        self.port = parsed.port ?? 322
        self.path = parsed.path.isEmpty ? "/" : parsed.path
    }

    // MARK: - Public API

    /// Runs the full OPTIONS → DESCRIBE → SETUP → PLAY handshake.
    ///
    /// - Returns: The parsed `SdpVideoTrack` from the DESCRIBE response.
    /// - Throws: `RtspError.timeout` if any request takes longer than 10 s,
    ///           `RtspError.authenticationFailed` if Digest auth fails,
    ///           `RtspError.noVideoTrack` if the SDP has no video section,
    ///           `RtspError.connectionFailed` for transport-level errors.
    func runHandshake() async throws -> SdpVideoTrack {
        // OPTIONS
        _ = try await sendRequest(method: "OPTIONS", uri: url)

        // DESCRIBE
        let describeResponse = try await sendRequest(method: "DESCRIBE", uri: url, extraHeaders: [
            "Accept": "application/sdp"
        ])
        guard let sdpBody = describeResponse.body, !sdpBody.isEmpty else {
            throw RtspError.noVideoTrack
        }
        let videoTrack = try SdpParser.parse(sdpBody)

        // Resolve the control URL (may be relative)
        let controlUrl = resolveControlUrl(videoTrack.controlUrl)

        // SETUP
        let setupResponse = try await sendRequest(method: "SETUP", uri: controlUrl, extraHeaders: [
            "Transport": "RTP/AVP/TCP;unicast;interleaved=0-1"
        ])
        // Extract session ID from SETUP response
        if let sessionHeader = setupResponse.headers["session"] {
            // Session header may include a timeout: "abc123;timeout=60"
            sessionId = sessionHeader.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces)
        }

        // PLAY
        var playHeaders: [String: String] = ["Range": "npt=0.000-"]
        if let sid = sessionId {
            playHeaders["Session"] = sid
        }
        _ = try await sendRequest(method: "PLAY", uri: url, extraHeaders: playHeaders)

        return videoTrack
    }

    /// Sends TEARDOWN and closes the transport.
    func teardown() async {
        var headers: [String: String] = [:]
        if let sid = sessionId {
            headers["Session"] = sid
        }
        // Best-effort — ignore errors during teardown
        _ = try? await sendRequest(method: "TEARDOWN", uri: url, extraHeaders: headers)
        transport.close()
    }

    // MARK: - Request / Response

    /// Builds and sends an RTSP request, then reads and parses the response.
    /// Retries once with Digest auth if the server returns 401.
    ///
    /// - Parameters:
    ///   - method: RTSP method string (e.g. "OPTIONS").
    ///   - uri: Request URI.
    ///   - extraHeaders: Additional headers to include.
    ///   - authHeader: Pre-computed Authorization header value (used on retry).
    /// - Returns: The parsed `RtspResponse`.
    @discardableResult
    private func sendRequest(
        method: String,
        uri: String,
        extraHeaders: [String: String] = [:],
        authHeader: String? = nil
    ) async throws -> RtspResponse {
        var headers = extraHeaders
        if let auth = authHeader {
            headers["Authorization"] = auth
        }

        let requestData = buildRequest(method: method, uri: uri, headers: headers)
        let response = try await withRequestTimeout {
            try await self.transport.send(data: requestData)
            return try await self.readResponse()
        }

        if response.statusCode == 401 {
            // Parse WWW-Authenticate and retry once with Digest credentials
            guard let wwwAuth = response.headers["www-authenticate"] else {
                throw RtspError.authenticationFailed
            }
            let digest = try parseDigestChallenge(wwwAuth)
            let computedAuth = buildDigestAuthorization(
                method: method,
                uri: uri,
                realm: digest.realm,
                nonce: digest.nonce
            )
            // Retry with auth — do NOT recurse again on another 401
            let retryHeaders = extraHeaders.merging(["Authorization": computedAuth]) { _, new in new }
            let retryData = buildRequest(method: method, uri: uri, headers: retryHeaders)
            let retryResponse = try await withRequestTimeout {
                try await self.transport.send(data: retryData)
                return try await self.readResponse()
            }
            if retryResponse.statusCode == 401 {
                throw RtspError.authenticationFailed
            }
            return retryResponse
        }

        return response
    }

    /// Builds a raw RTSP request `Data` value.
    private func buildRequest(method: String, uri: String, headers: [String: String]) -> Data {
        var lines = "\(method) \(uri) RTSP/1.0\r\nCSeq: \(cseq)\r\n"
        cseq += 1
        for (key, value) in headers {
            lines += "\(key): \(value)\r\n"
        }
        lines += "\r\n"
        return Data(lines.utf8)
    }

    // MARK: - Response Reading

    /// Reads bytes from the transport until the RTSP response header terminator
    /// `\r\n\r\n` is found, then reads the body if `Content-Length` is present.
    ///
    /// Maintains a `lookahead` buffer so we can read in small chunks without
    /// ever discarding bytes that belong to the body or the subsequent RTP stream.
    ///
    /// Handles interleaved RTP/RTCP frames (`$` prefix) that may arrive before
    /// OR between RTSP response lines on H2-series Bambu printers.
    private func readResponse() async throws -> RtspResponse {
        let terminator = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n

        // Bytes fetched from the transport but not yet consumed.
        var lookahead = Data()

        // Accumulates header bytes up to and including \r\n\r\n.
        var headerData = Data()

        while !headerData.hasSuffix(terminator) {
            // Refill lookahead if empty.
            if lookahead.isEmpty {
                let chunk = try await transport.receive(minimumLength: 1, maximumLength: 256)
                lookahead.append(chunk)
            }
            let byte = lookahead.removeFirst()

            // Interleaved RTP/RTCP frame: drain it entirely and restart.
            // This can arrive at ANY point — not just at the start of a response —
            // on H2-series Bambu printers that pipeline RTP before the RTSP reply.
            // We detect it when headerData ends on a line boundary (empty or after
            // a complete \r\n) so we don't misidentify a `$` inside a header value.
            let onLineBoundary = headerData.isEmpty ||
                headerData.hasSuffix(Data([0x0D, 0x0A]))
            if byte == 0x24 && onLineBoundary {
                // Need channel (1 byte) + length (2 bytes).
                while lookahead.count < 3 {
                    let more = try await transport.receive(minimumLength: 1, maximumLength: 3 - lookahead.count)
                    lookahead.append(more)
                }
                // Read length before mutating lookahead.
                let lenHi = lookahead[1]
                let lenLo = lookahead[2]
                lookahead.removeFirst(3)
                let payloadLength = Int(lenHi) << 8 | Int(lenLo)

                if payloadLength > 0 {
                    if lookahead.count >= payloadLength {
                        lookahead.removeFirst(payloadLength)
                    } else {
                        var remaining = payloadLength - lookahead.count
                        lookahead.removeAll()
                        while remaining > 0 {
                            let drain = try await transport.receive(
                                minimumLength: 1,
                                maximumLength: min(remaining, 4096)
                            )
                            remaining -= drain.count
                        }
                    }
                }
                continue
            }

            headerData.append(byte)
            if headerData.count > 65_536 {
                throw RtspError.connectionFailed("RTSP response headers exceeded 64 KB")
            }
        }

        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw RtspError.connectionFailed("RTSP response is not valid UTF-8")
        }

        let response = try parseResponseHeaders(headerString)

        // Read body if Content-Length is present, consuming lookahead first.
        if let lengthStr = response.headers["content-length"],
           let length = Int(lengthStr.trimmingCharacters(in: .whitespaces)),
           length > 0 {
            var bodyData = Data()

            let fromLookahead = min(lookahead.count, length)
            if fromLookahead > 0 {
                bodyData.append(lookahead.prefix(fromLookahead))
                lookahead.removeFirst(fromLookahead)
            }

            while bodyData.count < length {
                let remaining = length - bodyData.count
                let chunk = try await transport.receive(minimumLength: 1, maximumLength: remaining)
                bodyData.append(chunk)
            }
            return RtspResponse(
                statusCode: response.statusCode,
                reason: response.reason,
                headers: response.headers,
                body: String(data: bodyData, encoding: .utf8)
            )
        }

        return response
    }

    /// Parses the header section of an RTSP response.
    private func parseResponseHeaders(_ raw: String) throws -> RtspResponse {
        // Split on \r\n; first line is the status line
        let lines = raw.components(separatedBy: "\r\n")
        guard let statusLine = lines.first, !statusLine.isEmpty else {
            throw RtspError.connectionFailed("Empty RTSP response")
        }

        // Status line: RTSP/1.0 200 OK
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2,
              let code = Int(parts[1]) else {
            throw RtspError.connectionFailed("Malformed RTSP status line: \(statusLine)")
        }
        let reason = parts.count >= 3 ? String(parts[2]) : ""

        // Parse headers as lowercased key → value
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.isEmpty else { continue }
            if let colonIdx = line.firstIndex(of: ":") {
                let key = String(line[line.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        return RtspResponse(statusCode: code, reason: reason, headers: headers, body: nil)
    }

    // MARK: - Timeout

    /// Wraps an async operation in a 10-second timeout.
    /// Throws `RtspError.timeout` if the operation does not complete in time.
    private func withRequestTimeout<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                throw RtspError.timeout
            }
            // Return the first result (success or error) and cancel the other task
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - Control URL Resolution

    /// Resolves a potentially relative control URL against the base stream URL.
    private func resolveControlUrl(_ controlUrl: String) -> String {
        // Absolute URL — use as-is
        if controlUrl.lowercased().hasPrefix("rtsp://") ||
           controlUrl.lowercased().hasPrefix("rtsps://") {
            return controlUrl
        }
        // Wildcard — use base URL
        if controlUrl == "*" {
            return url
        }
        // Relative — append to base URL
        let base = url.hasSuffix("/") ? url : url + "/"
        return base + controlUrl
    }

    // MARK: - Digest Authentication

    private struct DigestChallenge {
        let realm: String
        let nonce: String
    }

    /// Parses `realm` and `nonce` from a `WWW-Authenticate: Digest ...` header value.
    private func parseDigestChallenge(_ header: String) throws -> DigestChallenge {
        func extractQuoted(_ key: String, from str: String) -> String? {
            guard let keyRange = str.range(of: "\(key)=\"") else { return nil }
            let afterKey = str[keyRange.upperBound...]
            guard let closeQuote = afterKey.firstIndex(of: "\"") else { return nil }
            return String(afterKey[..<closeQuote])
        }

        guard let realm = extractQuoted("realm", from: header),
              let nonce = extractQuoted("nonce", from: header) else {
            throw RtspError.authenticationFailed
        }
        return DigestChallenge(realm: realm, nonce: nonce)
    }

    /// Builds the `Authorization: Digest ...` header value.
    private func buildDigestAuthorization(method: String, uri: String, realm: String, nonce: String) -> String {
        let ha1 = md5("\(username):\(realm):\(password)")
        let ha2 = md5("\(method):\(uri)")
        let response = md5("\(ha1):\(nonce):\(ha2)")
        return "Digest username=\"\(username)\", realm=\"\(realm)\", nonce=\"\(nonce)\", uri=\"\(uri)\", response=\"\(response)\""
    }

    // MARK: - MD5 Helper

    /// Computes the lowercase hex MD5 digest of a UTF-8 string.
    private func md5(_ string: String) -> String {
        let data = Data(string.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_MD5(ptr.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - RtspResponse

/// Parsed RTSP response.
struct RtspResponse {
    let statusCode: Int
    let reason: String
    /// All header names are lowercased for case-insensitive lookup.
    let headers: [String: String]
    /// Response body, present only when `Content-Length` > 0.
    let body: String?
}

// MARK: - Data extension

private extension Data {
    /// Returns `true` if this `Data` ends with the given suffix.
    func hasSuffix(_ suffix: Data) -> Bool {
        guard count >= suffix.count else { return false }
        return suffix == self[(count - suffix.count)...]
    }
}
