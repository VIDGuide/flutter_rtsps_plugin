import CryptoKit
import Foundation
import os.log

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
    /// **Single-caller assumption (Defect 1.32)**: During the handshake phase,
    /// all requests are sequential (awaited). During the streaming phase,
    /// only `sendGetParameter()` may use this counter, and it should be
    /// called from a single serial context (e.g. a timer on a dedicated queue).
    private var cseq: Int = 1

    /// Session ID returned by the server in the SETUP response.
    private var sessionId: String?

    /// Server session timeout in seconds, parsed from the Session header's
    /// `timeout=N` parameter (Defect 1.13).
    private var serverTimeout: Int?

    /// Unconsumed lookahead bytes remaining after the last `readResponse()`.
    /// These may contain the beginning of the RTP interleaved stream and must
    /// be forwarded to the `RtpDemuxer` (Defect 1.12).
    var remainingData: Data?

    private let log = OSLog(subsystem: "com.pandawatch.flutter_rtsps_plugin", category: "RtspStateMachine")

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
    func runHandshake(preferUdp: Bool = true) async throws -> HandshakeResult {
        // OPTIONS
        let optionsResponse = try await sendRequest(method: "OPTIONS", uri: url)
        os_log("RTSP OPTIONS %d %{public}@", log: log, type: .info,
               optionsResponse.statusCode, optionsResponse.reason)
        if let publicHeader = optionsResponse.headers["public"] {
            os_log("  Public: %{public}@", log: log, type: .info, publicHeader)
        }
        logAllHeaders("OPTIONS", optionsResponse)

        // DESCRIBE
        let describeResponse = try await sendRequest(method: "DESCRIBE", uri: url, extraHeaders: [
            "Accept": "application/sdp"
        ])
        os_log("RTSP DESCRIBE %d %{public}@", log: log, type: .info,
               describeResponse.statusCode, describeResponse.reason)
        logAllHeaders("DESCRIBE", describeResponse)
        guard let sdpBody = describeResponse.body, !sdpBody.isEmpty else {
            throw RtspError.noVideoTrack
        }
        // Log SDP body line by line (truncate very long lines)
        for sdpLine in sdpBody.components(separatedBy: "\r\n") where !sdpLine.isEmpty {
            let truncated = sdpLine.count > 200 ? String(sdpLine.prefix(200)) + "..." : sdpLine
            os_log("  SDP: %{public}@", log: log, type: .info, truncated)
        }
        let videoTrack = try SdpParser.parse(sdpBody)

        // Resolve the control URL (may be relative)
        let controlUrl = resolveControlUrl(videoTrack.controlUrl)

        // SETUP — try UDP first (if preferred), fall back to TCP interleaved.
        // The H2C's TLS+TCP path bottlenecks on the server's ARM CPU,
        // causing periodic stalls. UDP bypasses TCP flow control entirely.
        // Note: even over an rtsps:// connection, LIVE555 can accept UDP
        // transport for the media — only the RTSP signaling uses TLS/TCP.
        var useUdp = false
        var serverRtpPort: UInt16 = 0
        var serverRtcpPort: UInt16 = 0
        let udpClientRtpPort: UInt16 = 50000 + UInt16.random(in: 0...999) * 2
        let udpClientRtcpPort = udpClientRtpPort + 1

        let setupResponse: RtspResponse

        if preferUdp {
            let udpTransportHeader = "RTP/AVP/UDP;unicast;client_port=\(udpClientRtpPort)-\(udpClientRtcpPort)"

            let udpSetupResponse = try await sendRequest(method: "SETUP", uri: controlUrl, extraHeaders: [
                "Transport": udpTransportHeader
            ])
            os_log("RTSP SETUP (UDP attempt) %d %{public}@", log: log, type: .info,
                   udpSetupResponse.statusCode, udpSetupResponse.reason)
            if let transportHeader = udpSetupResponse.headers["transport"] {
                os_log("  Transport: %{public}@", log: log, type: .info, transportHeader)
            }
            logAllHeaders("SETUP-UDP", udpSetupResponse)

            if udpSetupResponse.statusCode == 200,
               let transportHeader = udpSetupResponse.headers["transport"],
               transportHeader.lowercased().contains("rtp/avp") && !transportHeader.lowercased().contains("tcp") {
                // Server accepted UDP — parse server_port from Transport header
                useUdp = true
                setupResponse = udpSetupResponse
                let ports = Self.parseServerPorts(from: transportHeader)
                serverRtpPort = ports.rtp
                serverRtcpPort = ports.rtcp
                os_log("RTSP SETUP: server accepted UDP (server_port=%u-%u, client_port=%u-%u)",
                       log: log, type: .info, serverRtpPort, serverRtcpPort, udpClientRtpPort, udpClientRtcpPort)
            } else {
                // Server rejected UDP (461 or returned TCP) — fall back to TCP interleaved
                os_log("RTSP SETUP: server rejected UDP (%d), falling back to TCP interleaved",
                       log: log, type: .info, udpSetupResponse.statusCode)

                if udpSetupResponse.statusCode == 200 {
                    // Server returned 200 but with TCP transport — use it
                    setupResponse = udpSetupResponse
                } else {
                    // Send a new SETUP requesting TCP interleaved
                    let tcpSetupResponse = try await sendRequest(method: "SETUP", uri: controlUrl, extraHeaders: [
                        "Transport": "RTP/AVP/TCP;unicast;interleaved=0-1"
                    ])
                    os_log("RTSP SETUP (TCP fallback) %d %{public}@", log: log, type: .info,
                           tcpSetupResponse.statusCode, tcpSetupResponse.reason)
                    if let transportHeader = tcpSetupResponse.headers["transport"] {
                        os_log("  Transport: %{public}@", log: log, type: .info, transportHeader)
                    }
                    logAllHeaders("SETUP-TCP", tcpSetupResponse)
                    setupResponse = tcpSetupResponse
                }
            }
        } else {
            // Direct TCP — no UDP attempt (used by SnapshotCapture)
            let tcpSetupResponse = try await sendRequest(method: "SETUP", uri: controlUrl, extraHeaders: [
                "Transport": "RTP/AVP/TCP;unicast;interleaved=0-1"
            ])
            os_log("RTSP SETUP %d %{public}@", log: log, type: .info,
                   tcpSetupResponse.statusCode, tcpSetupResponse.reason)
            if let transportHeader = tcpSetupResponse.headers["transport"] {
                os_log("  Transport: %{public}@", log: log, type: .info, transportHeader)
            }
            logAllHeaders("SETUP", tcpSetupResponse)
            setupResponse = tcpSetupResponse
        }

        if let sessionHeader = setupResponse.headers["session"] {
            os_log("  Session: %{public}@", log: log, type: .info, sessionHeader)
        }

        // Extract session ID and timeout from SETUP response (Defect 1.13)
        if let sessionHeader = setupResponse.headers["session"] {
            let parts = sessionHeader.components(separatedBy: ";")
            sessionId = parts.first?.trimmingCharacters(in: .whitespaces)
            // Parse timeout=N from remaining parts
            for part in parts.dropFirst() {
                let trimmed = part.trimmingCharacters(in: .whitespaces).lowercased()
                if trimmed.hasPrefix("timeout="),
                   let value = Int(trimmed.dropFirst("timeout=".count)) {
                    serverTimeout = value
                }
            }
        }

        // PLAY
        var playHeaders: [String: String] = ["Range": "npt=0.000-"]
        if let sid = sessionId {
            playHeaders["Session"] = sid
        }
        let playResponse = try await sendRequest(method: "PLAY", uri: url, extraHeaders: playHeaders)
        os_log("RTSP PLAY %d %{public}@", log: log, type: .info,
               playResponse.statusCode, playResponse.reason)
        if let rtpInfo = playResponse.headers["rtp-info"] {
            os_log("  RTP-Info: %{public}@", log: log, type: .info, rtpInfo)
        }
        logAllHeaders("PLAY", playResponse)

        // Capture any unconsumed lookahead bytes from the last readResponse()
        // so they can be forwarded to the RtpDemuxer (Defect 1.12).
        let leftover = remainingData
        remainingData = nil

        return HandshakeResult(
            videoTrack: videoTrack,
            remainingData: leftover,
            serverTimeout: serverTimeout,
            udpTransport: useUdp ? UdpTransportInfo(
                serverHost: host,
                serverRtpPort: serverRtpPort,
                serverRtcpPort: serverRtcpPort,
                clientRtpPort: udpClientRtpPort,
                clientRtcpPort: udpClientRtcpPort
            ) : nil
        )
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

    /// Sends a GET_PARAMETER keepalive request to prevent the server from
    /// timing out the session. Only useful when the server advertises a
    /// short session timeout (Defect 1.29).
    ///
    /// - Note: This method shares the `cseq` counter with `sendRequest`.
    ///   It is safe to call concurrently with the streaming phase because
    ///   the handshake has already completed and no other RTSP requests
    ///   are in flight. See Defect 1.32 for the single-caller assumption.
    func sendGetParameter() async throws {
        guard let sid = sessionId else { return }
        let headers = ["Session": sid]
        _ = try await sendRequest(method: "GET_PARAMETER", uri: url, extraHeaders: headers)
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
                nonce: digest.nonce,
                qop: digest.qop
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
        var lines = "\(method) \(uri) RTSP/1.0\r\nCSeq: \(cseq)\r\nUser-Agent: Bambu-Client/1.0\r\n"
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
            // H2-series Bambu printers pipeline RTP data at ANY point during
            // the RTSP handshake — including mid-header-line. We detect an
            // interleaved frame by checking for 0x24 ($) followed by a valid
            // channel byte (0 or 1). The '$' character CAN appear in RTSP
            // header values, but never followed by 0x00 or 0x01 in valid
            // ASCII/UTF-8 text, so this is a safe heuristic.
            if byte == 0x24 {
                // Peek at the channel byte
                while lookahead.isEmpty {
                    let more = try await transport.receive(minimumLength: 1, maximumLength: 256)
                    lookahead.append(more)
                }
                let channelByte = lookahead[lookahead.startIndex]

                if channelByte <= 1 {
                    // Valid interleaved frame — drain channel + length + payload
                    lookahead.removeFirst() // consume channel byte
                    while lookahead.count < 2 {
                        let more = try await transport.receive(minimumLength: 1, maximumLength: 2 - lookahead.count)
                        lookahead.append(more)
                    }
                    let base = lookahead.startIndex
                    let payloadLength = Int(lookahead[base]) << 8 | Int(lookahead[base + 1])
                    lookahead.removeFirst(2)

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
                // Not a valid channel — fall through and treat '$' as a header byte
            }

            headerData.append(byte)
            // H2-series Bambu printers can send RTSP responses well over 64 KB
            // (e.g. large SDP bodies in DESCRIBE). 256 KB accommodates these
            // while still guarding against runaway reads.
            if headerData.count > 262_144 {
                throw RtspError.connectionFailed("RTSP response headers exceeded 256 KB")
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

            // Store any unconsumed lookahead bytes so they are not lost (Defect 1.12).
            if !lookahead.isEmpty {
                remainingData = lookahead
            }

            return RtspResponse(
                statusCode: response.statusCode,
                reason: response.reason,
                headers: response.headers,
                body: String(data: bodyData, encoding: .utf8)
            )
        }

        // Store any unconsumed lookahead bytes so they are not lost (Defect 1.12).
        if !lookahead.isEmpty {
            remainingData = lookahead
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

    // MARK: - Handshake Logging

    /// Logs all response headers for a given RTSP method at debug level.
    /// The key headers (Public, Transport, Session, RTP-Info) are already
    /// logged at info level individually — this captures everything else
    /// (e.g. Server, Date, Cache-Control, x-* vendor headers) that might
    /// reveal firmware-specific behavior.
    private func logAllHeaders(_ method: String, _ response: RtspResponse) {
        // Skip the headers we already log individually at info level
        let alreadyLogged: Set<String> = ["public", "transport", "session", "rtp-info", "content-length", "content-type"]
        for (key, value) in response.headers where !alreadyLogged.contains(key) {
            os_log("  %{public}@ %{public}@: %{public}@", log: log, type: .debug, method, key, value)
        }
    }

    // MARK: - Transport Parsing

    /// Parses `server_port=XXXX-YYYY` from a SETUP Transport response header.
    static func parseServerPorts(from transport: String) -> (rtp: UInt16, rtcp: UInt16) {
        // Look for server_port=XXXX-YYYY
        let pattern = "server_port=(\\d+)-(\\d+)"
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: transport, range: NSRange(transport.startIndex..., in: transport)),
           match.numberOfRanges >= 3,
           let rtpRange = Range(match.range(at: 1), in: transport),
           let rtcpRange = Range(match.range(at: 2), in: transport),
           let rtp = UInt16(transport[rtpRange]),
           let rtcp = UInt16(transport[rtcpRange]) {
            return (rtp, rtcp)
        }
        return (6970, 6971) // LIVE555 defaults
    }

    // MARK: - Digest Authentication

    private struct DigestChallenge {
        let realm: String
        let nonce: String
        let qop: String?  // e.g. "auth" or "auth,auth-int"
    }

    /// Nonce count for Digest auth with qop=auth, incremented per request.
    private var nonceCount: Int = 0

    /// Parses `realm`, `nonce`, and optional `qop` from a `WWW-Authenticate: Digest ...` header value.
    private func parseDigestChallenge(_ header: String) throws -> DigestChallenge {
        func extractQuoted(_ key: String, from str: String) -> String? {
            guard let keyRange = str.range(of: "\(key)=\"") else { return nil }
            let afterKey = str[keyRange.upperBound...]
            guard let closeQuote = afterKey.firstIndex(of: "\"") else { return nil }
            return String(afterKey[..<closeQuote])
        }

        /// Extracts an unquoted parameter value (e.g. `qop=auth`).
        func extractUnquoted(_ key: String, from str: String) -> String? {
            guard let keyRange = str.range(of: "\(key)=") else { return nil }
            let afterKey = str[keyRange.upperBound...]
            // Value ends at comma, space, or end of string
            let endIdx = afterKey.firstIndex(where: { $0 == "," || $0 == " " || $0 == "\t" }) ?? afterKey.endIndex
            let value = String(afterKey[..<endIdx])
            return value.isEmpty ? nil : value
        }

        guard let realm = extractQuoted("realm", from: header),
              let nonce = extractQuoted("nonce", from: header) else {
            throw RtspError.authenticationFailed
        }

        // qop may be quoted or unquoted per RFC 2617
        let qop = extractQuoted("qop", from: header)
            ?? extractUnquoted("qop", from: header)

        return DigestChallenge(realm: realm, nonce: nonce, qop: qop)
    }

    /// Builds the `Authorization: Digest ...` header value.
    /// When `qop` contains `auth`, includes `cnonce`, `nc`, and `qop=auth` per RFC 2617.
    /// When `qop` is nil, uses the simple Digest computation (backward compatible).
    private func buildDigestAuthorization(method: String, uri: String, realm: String, nonce: String, qop: String? = nil) -> String {
        let ha1 = md5("\(username):\(realm):\(password)")
        let ha2 = md5("\(method):\(uri)")

        if let qop = qop, qop.contains("auth") {
            nonceCount += 1
            let nc = String(format: "%08x", nonceCount)
            let cnonce = String(format: "%08x", UInt32.random(in: 0...UInt32.max))
            let response = md5("\(ha1):\(nonce):\(nc):\(cnonce):auth:\(ha2)")
            return "Digest username=\"\(username)\", realm=\"\(realm)\", nonce=\"\(nonce)\", uri=\"\(uri)\", qop=auth, nc=\(nc), cnonce=\"\(cnonce)\", response=\"\(response)\""
        } else {
            let response = md5("\(ha1):\(nonce):\(ha2)")
            return "Digest username=\"\(username)\", realm=\"\(realm)\", nonce=\"\(nonce)\", uri=\"\(uri)\", response=\"\(response)\""
        }
    }

    // MARK: - Testing Shims

    /// Exposes `buildDigestAuthorization` for unit tests, with optional qop support.
    func buildDigestAuthorizationForTesting(
        method: String,
        uri: String,
        realm: String,
        nonce: String,
        qop: String? = nil
    ) -> String {
        return buildDigestAuthorization(method: method, uri: uri, realm: realm, nonce: nonce, qop: qop)
    }

    /// Exposes `md5` for unit tests.
    func md5ForTesting(_ string: String) -> String {
        return md5(string)
    }

    /// Indicates that the MD5 implementation uses CryptoKit (not deprecated CommonCrypto CC_MD5).
    /// Used by bug condition exploration tests to verify the migration (Req 2.31).
    static let usesCryptoKitMD5: Bool = true

    // MARK: - MD5 Helper

    /// Computes the lowercase hex MD5 digest of a UTF-8 string.
    private func md5(_ string: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - UdpTransportInfo

/// UDP transport parameters negotiated during SETUP, used by the session
/// to create UDP sockets for RTP/RTCP instead of TCP interleaved framing.
struct UdpTransportInfo {
    let serverHost: String
    let serverRtpPort: UInt16
    let serverRtcpPort: UInt16
    let clientRtpPort: UInt16
    let clientRtcpPort: UInt16
}

// MARK: - HandshakeResult

/// Result of a successful RTSP handshake, containing the video track info,
/// any unconsumed lookahead bytes from the transport, and the server session timeout.
struct HandshakeResult {
    /// The parsed video track from the SDP DESCRIBE response.
    let videoTrack: SdpVideoTrack
    /// Bytes remaining in the read buffer after the final RTSP response.
    /// These may contain the start of the RTP interleaved stream and must
    /// be passed to the `RtpDemuxer` so they are not lost (Defect 1.12).
    let remainingData: Data?
    /// Server session timeout in seconds parsed from the Session header's
    /// `timeout=N` parameter, or `nil` if not provided (Defect 1.13).
    let serverTimeout: Int?
    /// UDP transport info if the server accepted UDP, or `nil` for TCP interleaved.
    let udpTransport: UdpTransportInfo?
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
