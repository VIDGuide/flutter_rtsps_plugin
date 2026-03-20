import Foundation
import os.log

// MARK: - UdpMediaTransport

/// Receives RTP and RTCP packets over UDP using POSIX BSD sockets,
/// dispatching them to callbacks compatible with `RtpDemuxer` and `RtcpSender`.
///
/// Used when the RTSP SETUP negotiation succeeds with UDP transport,
/// bypassing TCP interleaved framing. This avoids TCP/TLS backpressure
/// that causes stream stalling on some Bambu printer firmware (notably H2C).
///
/// Uses raw POSIX sockets (`socket()`, `bind()`, `sendto()`, `recvfrom()`)
/// instead of `NWConnection` because:
/// - Python probe scripts using raw sockets stream the H2C perfectly (454
///   packets, zero stalls over 45 seconds).
/// - `NWConnection`'s "connected UDP" semantics may filter packets or
///   handle the NAT punch + receive pattern differently.
/// - POSIX sockets give us full control over binding, timeouts, and
///   non-blocking I/O.
final class UdpMediaTransport {

    // MARK: - Callbacks

    /// Called with each received RTP packet payload.
    var onRtpPacket: ((Data) -> Void)?

    /// Called with each received RTCP packet payload.
    var onRtcpPacket: ((Data) -> Void)?

    /// Called when a fatal error occurs on either socket.
    var onError: ((Error) -> Void)?

    // MARK: - Private state

    private let serverHost: String
    private let serverRtpPort: UInt16
    private let serverRtcpPort: UInt16
    private let clientRtpPort: UInt16
    private let clientRtcpPort: UInt16

    /// POSIX socket file descriptors. -1 means not open.
    private var rtpSocket: Int32 = -1
    private var rtcpSocket: Int32 = -1

    /// Server address structs for sendto()
    private var serverRtpAddr = sockaddr_in()
    private var serverRtcpAddr = sockaddr_in()

    private let rtpQueue = DispatchQueue(label: "com.pandawatch.flutter_rtsps_plugin.udp.rtp", qos: .userInteractive)
    private let rtcpQueue = DispatchQueue(label: "com.pandawatch.flutter_rtsps_plugin.udp.rtcp", qos: .userInteractive)
    private var running = false

    private let log = OSLog(subsystem: "com.pandawatch.flutter_rtsps_plugin", category: "UdpMediaTransport")

    /// Maximum UDP datagram size. RTP over UDP typically fits in one
    /// Ethernet MTU (~1500 bytes) but we allocate extra for jumbo frames.
    private static let maxPacketSize = 65536

    // MARK: - Init

    init(info: UdpTransportInfo) {
        self.serverHost = info.serverHost
        self.serverRtpPort = info.serverRtpPort
        self.serverRtcpPort = info.serverRtcpPort
        self.clientRtpPort = info.clientRtpPort
        self.clientRtcpPort = info.clientRtcpPort
    }

    // MARK: - Start

    /// Creates and binds UDP sockets, sends NAT punch packets, and begins
    /// receiving RTP/RTCP packets on background threads.
    func start() throws {
        running = true

        // Resolve server IP
        guard let serverIP = resolveHost(serverHost) else {
            throw RtspError.connectionFailed("UdpMediaTransport: cannot resolve host \(serverHost)")
        }

        // Build server address structs
        serverRtpAddr = makeAddr(ip: serverIP, port: serverRtpPort)
        serverRtcpAddr = makeAddr(ip: serverIP, port: serverRtcpPort)

        // Create and bind RTP socket
        rtpSocket = try createAndBind(port: clientRtpPort)

        // Create and bind RTCP socket
        rtcpSocket = try createAndBind(port: clientRtcpPort)

        // Send NAT punch packets to open the firewall/NAT mapping.
        // The server expects to see traffic from our client ports before
        // it will send RTP/RTCP data to us.
        sendPunch(socket: rtpSocket, addr: &serverRtpAddr)
        sendPunch(socket: rtcpSocket, addr: &serverRtcpAddr)

        os_log("UdpMediaTransport: started (server=%{public}@:%u/%u, client=%u/%u, fd=%d/%d)",
               log: log, type: .info,
               serverHost, serverRtpPort, serverRtcpPort,
               clientRtpPort, clientRtcpPort,
               rtpSocket, rtcpSocket)

        // Start receive loops on separate queues (blocking recvfrom needs its own thread)
        let rtpFd = rtpSocket
        let rtcpFd = rtcpSocket

        // Log immediately to confirm loops are launching
        os_log("UdpMediaTransport: launching RTP receive loop on fd=%d, RTCP on fd=%d",
               log: log, type: .info, rtpFd, rtcpFd)

        rtpQueue.async { [weak self] in
            self?.receiveLoop(socket: rtpFd, label: "RTP") { data in
                self?.onRtpPacket?(data)
            }
        }
        rtcpQueue.async { [weak self] in
            self?.receiveLoop(socket: rtcpFd, label: "RTCP") { data in
                self?.onRtcpPacket?(data)
            }
        }
    }

    // MARK: - Send RTCP

    /// Sends an RTCP packet (e.g. Receiver Report) to the server's RTCP port.
    func sendRtcp(_ data: Data) {
        guard rtcpSocket >= 0 else { return }
        data.withUnsafeBytes { rawBuf in
            guard let ptr = rawBuf.baseAddress else { return }
            var addr = serverRtcpAddr
            withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    let sent = sendto(rtcpSocket, ptr, data.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    if sent < 0 {
                        os_log("UdpMediaTransport: RTCP sendto error: %d", log: log, type: .error, errno)
                    }
                }
            }
        }
    }

    // MARK: - Stop

    func stop() {
        running = false
        // Close sockets — this will cause recvfrom() to return with EBADF,
        // breaking the receive loops.
        if rtpSocket >= 0 {
            Darwin.close(rtpSocket)
            rtpSocket = -1
        }
        if rtcpSocket >= 0 {
            Darwin.close(rtcpSocket)
            rtcpSocket = -1
        }
        os_log("UdpMediaTransport: stopped", log: log, type: .info)
    }

    // MARK: - Private — Socket Creation

    /// Creates a UDP socket, sets it non-blocking-ish with a receive timeout,
    /// enables address reuse, and binds to the specified local port.
    private func createAndBind(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            throw RtspError.connectionFailed("UdpMediaTransport: socket() failed: errno=\(errno)")
        }

        // Allow port reuse in case of rapid reconnect
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        // Set receive timeout so recvfrom() doesn't block forever.
        // 200ms gives us responsive shutdown while not burning CPU.
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Increase receive buffer to 512KB to handle bursty RTP traffic.
        // The kernel may cap this at a lower value — verify and log.
        var rcvBuf: Int32 = 524_288
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvBuf, socklen_t(MemoryLayout<Int32>.size))
        var actualBuf: Int32 = 0
        var actualLen = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_RCVBUF, &actualBuf, &actualLen)
        if actualBuf < rcvBuf {
            os_log("UdpMediaTransport: SO_RCVBUF requested %d, got %d",
                   log: log, type: .info, rcvBuf, actualBuf)
        }

        // Bind to 0.0.0.0:<port>
        var bindAddr = sockaddr_in()
        bindAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        bindAddr.sin_family = sa_family_t(AF_INET)
        bindAddr.sin_port = port.bigEndian
        bindAddr.sin_addr.s_addr = INADDR_ANY.bigEndian

        let bindResult = withUnsafePointer(to: &bindAddr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if bindResult < 0 {
            Darwin.close(fd)
            throw RtspError.connectionFailed("UdpMediaTransport: bind() to port \(port) failed: errno=\(errno)")
        }

        return fd
    }

    // MARK: - Private — Receive Loop

    /// Diagnostic logging interval (seconds).
    private static let diagInterval: Double = 2.0

    /// Blocking receive loop that runs on a background queue.
    /// Uses `recvfrom()` with a 200ms timeout so we can check `running`
    /// periodically and exit cleanly when `stop()` is called.
    private func receiveLoop(socket fd: Int32, label: String, handler: @escaping (Data) -> Void) {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.maxPacketSize)
        defer { buffer.deallocate() }

        os_log("UdpMediaTransport: %{public}@ receive loop entered (fd=%d, running=%d)",
               log: log, type: .info, label, fd, running ? 1 : 0)

        var pktCount: UInt64 = 0
        var byteCount: UInt64 = 0
        let startTime = ProcessInfo.processInfo.systemUptime

        // Diagnostic counters
        var diagPktCount: UInt64 = 0
        var diagByteCount: UInt64 = 0
        var diagTime = startTime
        var timeoutCount: UInt64 = 0
        var lastPktTime = startTime
        var maxGap: Double = 0

        while running && fd >= 0 {
            var srcAddr = sockaddr_in()
            var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)

            let n = withUnsafeMutablePointer(to: &srcAddr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(fd, buffer, Self.maxPacketSize, 0, sa, &srcLen)
                }
            }

            let now = ProcessInfo.processInfo.systemUptime

            if n > 0 {
                let data = Data(bytes: buffer, count: n)
                pktCount += 1
                byteCount += UInt64(n)

                // Track inter-packet gap for stall diagnosis
                if pktCount > 1 {
                    let gap = now - lastPktTime
                    if gap > maxGap { maxGap = gap }
                }
                lastPktTime = now

                handler(data)
            } else if n < 0 {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK {
                    timeoutCount += 1
                    // Periodic diagnostic logging on timeout ticks
                    if now - diagTime >= Self.diagInterval {
                        let elapsed = now - diagTime
                        let pktDelta = pktCount - diagPktCount
                        let byteDelta = byteCount - diagByteCount
                        let pps = elapsed > 0 ? Double(pktDelta) / elapsed : 0
                        let kbps = elapsed > 0 ? Double(byteDelta) * 8.0 / elapsed / 1000.0 : 0
                        let sinceLastPkt = now - lastPktTime
                        os_log("UdpMediaTransport: [%{public}@] %.1fs: %llu pkts (%.0f pps, %.0f kbps) maxGap=%.2fs idle=%.1fs timeouts=%llu",
                               log: log, type: .info, label, elapsed,
                               pktDelta, pps, kbps, maxGap, sinceLastPkt, timeoutCount)
                        diagPktCount = pktCount
                        diagByteCount = byteCount
                        diagTime = now
                        maxGap = 0
                        timeoutCount = 0
                    }
                    continue
                }
                if err == EBADF || err == EINVAL {
                    // Socket was closed by stop() — exit cleanly
                    break
                }
                os_log("UdpMediaTransport: %{public}@ recvfrom error: errno=%d",
                       log: log, type: .error, label, err)
                if running {
                    onError?(RtspError.connectionFailed("UDP \(label) recv error: errno=\(err)"))
                }
                break
            } else {
                // n == 0: empty datagram, continue
                continue
            }
        }

        let elapsed = ProcessInfo.processInfo.systemUptime - startTime
        os_log("UdpMediaTransport: %{public}@ loop exited after %.1fs (%llu pkts, %llu bytes)",
               log: log, type: .info, label, elapsed, pktCount, byteCount)
    }

    // MARK: - Private — Helpers

    /// Sends a 4-byte punch packet to open the NAT/firewall mapping.
    private func sendPunch(socket fd: Int32, addr: inout sockaddr_in) {
        var punch: [UInt8] = [0x00, 0x00, 0x00, 0x00]
        withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                sendto(fd, &punch, punch.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    /// Builds a `sockaddr_in` for the given IPv4 address string and port.
    private func makeAddr(ip: String, port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, ip, &addr.sin_addr)
        return addr
    }

    /// Resolves a hostname to an IPv4 address string.
    /// For numeric IPs (like 192.168.1.144), this is a no-op passthrough.
    private func resolveHost(_ host: String) -> String? {
        var addr = in_addr()
        // Try direct numeric parse first
        if inet_pton(AF_INET, host, &addr) == 1 {
            return host
        }
        // DNS resolution fallback
        guard let hostent = gethostbyname(host) else { return nil }
        guard hostent.pointee.h_addrtype == AF_INET,
              let addrList = hostent.pointee.h_addr_list,
              let firstAddr = addrList[0] else { return nil }
        var resolvedAddr = in_addr()
        memcpy(&resolvedAddr, firstAddr, Int(hostent.pointee.h_length))
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &resolvedAddr, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
    }
}
