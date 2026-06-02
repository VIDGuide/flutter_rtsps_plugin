import Foundation
import os.log

// MARK: - RtcpSender

/// Sends periodic RTCP Receiver Report packets over the TCP interleaved
/// connection (channel 1) to prevent stream timeout on the server side.
///
/// The Bambu Lab printer stops sending video after ~1.8 seconds of buffered
/// frames if no RTCP keepalive is received. This class fires every 1 second
/// while the stream is active. (Req 3.1)
///
/// RTCP Receiver Report structure (RFC 3550):
///   Header (8 bytes):
///     V=2(2) P=0(1) RC=1(5) | PT=201(8) | length=7(16)
///     SSRC of packet sender (4 bytes) — random per RFC 3550 §6.4.2
///   Report block (24 bytes):
///     SSRC of source (4 bytes)
///     Fraction lost (1 byte) | Cumulative lost (3 bytes)
///     Extended highest seq received (4 bytes)
///     Interarrival jitter (4 bytes)
///     LSR — last SR timestamp (4 bytes)
///     DLSR — delay since last SR (4 bytes)
///   Total: 32 bytes → length field = (32/4) - 1 = 7
final class RtcpSender {

    // MARK: - Private state

    private let transport: RtspTransport
    private let onError: (Error) -> Void

    /// Optional UDP send handler. When set, RTCP packets are sent via this
    /// closure (raw RTCP, no TCP interleaved framing) instead of through
    /// the TCP transport. Set by `RtspStreamSession` when UDP transport
    /// is negotiated.
    var udpSendHandler: ((Data) -> Void)?

    private var timer: DispatchSourceTimer?
    private let timerQueue: DispatchQueue

    /// Unique instance counter for queue labelling.
    private static let counterLock = NSLock()
    private static var instanceCounter: Int = 0
    private static func nextId() -> Int {
        counterLock.lock()
        defer { counterLock.unlock() }
        instanceCounter += 1
        return instanceCounter
    }

    /// Guards against overlapping sends if a send takes longer than the 1-second interval.
    /// Only accessed on `timerQueue`.
    private var isSending = false

    /// Most recent RTP statistics snapshot, updated by `updateStats(_:)`.
    /// Only accessed on `timerQueue` to prevent torn reads/writes. (Req 2.4)
    private var stats = RtpStats(ssrc: 0, highestSeq: 0, packetCount: 0, octetCount: 0)

    /// Random receiver SSRC generated once per session per RFC 3550 §6.4.2. (Req 2.27)
    private let receiverSsrc: UInt32 = UInt32.random(in: 0...UInt32.max)

    // --- Jitter computation (RFC 3550 §6.4.1) ---

    /// Running interarrival jitter estimate (in RTP timestamp units).
    /// Updated on every stats update using the algorithm from RFC 3550 A.8.
    private var jitter: Double = 0

    /// Previous RTP timestamp, used for jitter delta computation.
    private var prevRtpTimestamp: UInt32 = 0
    /// Previous arrival time (seconds, monotonic), used for jitter delta computation.
    private var prevArrivalTime: Double = 0
    /// True once we have a previous sample to compute jitter against.
    private var hasJitterBaseline = false

    /// Assumed RTP clock rate (90 kHz for H.264 video per RFC 6184).
    private static let rtpClockRate: Double = 90_000

    // --- Fraction lost computation (RFC 3550 §6.4.1) ---

    /// Extended highest sequence number at the time of the previous RR.
    private var prevHighestSeq: UInt32 = 0
    /// Packet count at the time of the previous RR.
    private var prevPacketCount: UInt32 = 0
    /// True once we have a previous RR baseline for fraction lost.
    private var hasLostBaseline = false

    /// Initial extended highest sequence number, recorded on the first stats
    /// update. Used to compute cumulative packets lost for the RR report block.
    private var initialHighestSeq: UInt32 = 0
    /// True once we have recorded the initial sequence number.
    private var hasInitialSeq = false

    // --- SR tracking for LSR / DLSR (RFC 3550 §6.4.1) ---

    /// Middle 32 bits of the NTP timestamp from the most recent RTCP Sender
    /// Report received from the server. Zero if no SR has been received yet.
    private var lastSrNtpMiddle32: UInt32 = 0
    /// Wall-clock time (monotonic seconds) when the last SR was received.
    private var lastSrArrivalTime: Double = 0

    // --- Stall detection & adaptive RTCP rate ---

    /// Wall-clock time of the most recent RTP packet arrival.
    /// Updated by `updateStats()`, read by the timer to detect stalls.
    private var lastRtpArrivalTime: Double = 0

    /// Whether we are currently in "stall mode" (sending RRs at 250ms instead of 1s).
    private var isInStallMode = false

    /// Normal timer interval (seconds).
    private var normalInterval: TimeInterval = 1.0

    /// Fast timer interval used during detected stalls (seconds).
    private static let stallInterval: TimeInterval = 0.25

    /// How long without RTP packets before we consider the stream stalled (seconds).
    private static let stallThreshold: TimeInterval = 1.5

    /// Maximum per-packet jitter deviation fed into the EWMA (RTP timestamp units).
    /// 50ms × 90kHz = 4500 ticks. Anything larger is a stall artifact, not real
    /// network jitter, and would poison the reported jitter value.
    private static let maxJitterDeviation: Double = 4500

    /// Number of RTCP Sender Reports received from the server.
    private var srCount: UInt32 = 0

    /// Number of Receiver Reports we have sent.
    private var rrSentCount: UInt32 = 0

    private let log = OSLog(subsystem: "com.pandawatch.flutter_rtsps_plugin", category: "RtcpSender")

    // MARK: - Init

    /// - Parameters:
    ///   - transport: A connected `RtspTransport` in the streaming state.
    ///   - onError: Called on the timer queue when a write error occurs.
    ///              The caller should initiate teardown in response. (Req 3.4)
    init(transport: RtspTransport, onError: @escaping (Error) -> Void) {
        self.transport = transport
        self.onError = onError
        let id = RtcpSender.nextId()
        self.timerQueue = DispatchQueue(label: "com.pandawatch.flutter_rtsps_plugin.rtcp.\(id)")
    }

    // MARK: - Stats Update

    /// Updates the RTP statistics used to populate the next Receiver Report.
    /// Called by `RtpDemuxer`'s `onRtpStats` callback. (Req 3.2)
    /// Dispatches to `timerQueue` so reads and writes are serialized. (Req 2.4)
    ///
    /// Also computes interarrival jitter per RFC 3550 §6.4.1 / A.8.
    func updateStats(_ newStats: RtpStats) {
        timerQueue.async { [weak self] in
            guard let self else { return }

            // Compute interarrival jitter (RFC 3550 A.8)
            // Clamp the per-packet deviation to 50ms (4500 RTP ticks at 90kHz)
            // so that stall-recovery bursts don't inflate the reported jitter.
            // LIVE555 may use reported jitter for send pacing — reporting
            // multi-second jitter after a burst could cause the server to
            // throttle its send rate, creating a feedback loop that worsens
            // the stalling on the H2C.
            if self.hasJitterBaseline && newStats.arrivalTime > 0 {
                let arrivalDelta = (newStats.arrivalTime - self.prevArrivalTime) * RtcpSender.rtpClockRate
                let rtpDelta = Double(Int32(bitPattern: newStats.rtpTimestamp &- self.prevRtpTimestamp))
                let d = min(abs(arrivalDelta - rtpDelta), RtcpSender.maxJitterDeviation)
                self.jitter += (d - self.jitter) / 16.0
            }

            if newStats.arrivalTime > 0 {
                self.prevRtpTimestamp = newStats.rtpTimestamp
                self.prevArrivalTime = newStats.arrivalTime
                self.hasJitterBaseline = true
                self.lastRtpArrivalTime = newStats.arrivalTime
            }

            // Record the initial sequence number for cumulative lost computation.
            if !self.hasInitialSeq && newStats.highestSeq > 0 {
                self.initialHighestSeq = newStats.highestSeq
                self.hasInitialSeq = true
            }

            // If we were in stall mode and packets are flowing again, switch back
            // to normal interval. Reset the jitter baseline AND the accumulated
            // jitter EWMA so the first packet of the new burst isn't compared
            // against the last packet before the stall, and so the reported
            // jitter doesn't carry over an inflated value from the stall period.
            if self.isInStallMode {
                self.isInStallMode = false
                self.hasJitterBaseline = false
                self.jitter = 0
                self.rescheduleTimer(interval: self.normalInterval)
                os_log("RtcpSender: stall ended, reverting to %.1fs interval (seq=%u)",
                       log: self.log, type: .info, self.normalInterval, newStats.highestSeq)
            }

            self.stats = newStats
        }
    }

    /// Processes an incoming RTCP packet from the server (forwarded by the
    /// demuxer's `onRtcpPacket` callback). Extracts the NTP timestamp from
    /// Sender Report (PT=200) packets for LSR/DLSR computation.
    ///
    /// Immediately sends an RTCP Receiver Report in response to each SR.
    /// Some Bambu printer firmware (notably the H2C) appears to gate its
    /// RTP encoder on receiving a timely RR after each SR — without this
    /// prompt response the encoder stalls for 4-9 seconds between bursts.
    /// Sending an RR immediately after the SR (rather than waiting for the
    /// next 1-second timer tick) keeps the encoder running smoothly.
    func processRtcpPacket(_ data: Data) {
        // Minimum RTCP SR: 4-byte header + 4-byte SSRC + 20-byte sender info = 28 bytes
        guard data.count >= 28 else { return }

        let pt = data[1]
        guard pt == 200 else { return } // Only process Sender Reports

        // NTP timestamp: bytes 8-15 (after 4-byte header + 4-byte SSRC)
        // LSR = middle 32 bits = low 16 of NTP seconds | high 16 of NTP fraction
        let ntpSecondsLo = UInt16(data[10]) << 8 | UInt16(data[11])
        let ntpFractionHi = UInt16(data[12]) << 8 | UInt16(data[13])
        // Middle 32 bits: low 16 of seconds | high 16 of fraction
        let lsr = UInt32(ntpSecondsLo) << 16 | UInt32(ntpFractionHi)

        let arrivalTime = ProcessInfo.processInfo.systemUptime

        timerQueue.async { [weak self] in
            guard let self else { return }
            self.lastSrNtpMiddle32 = lsr
            self.lastSrArrivalTime = arrivalTime
            self.srCount += 1

            let stallDuration: Double
            if self.lastRtpArrivalTime > 0 {
                stallDuration = arrivalTime - self.lastRtpArrivalTime
            } else {
                stallDuration = 0
            }

            os_log("RtcpSender: received SR #%u LSR=0x%08x (%.1fs since last RTP, seq=%u)",
                   log: self.log, type: .info,
                   self.srCount, lsr, stallDuration, self.stats.highestSeq)

            // Immediately send an RR in response to the SR.
            self.sendReceiverReport()
        }
    }

    // MARK: - Lifecycle

    /// Creates and starts a `DispatchSourceTimer` on a background queue. (Req 3.1)
    ///
    /// - Parameter interval: Seconds between Receiver Reports. Defaults to 1.0.
    ///   When the server advertises a session timeout, callers should pass
    ///   `min(1.0, timeout / 3)` so the keepalive fires well within the
    ///   server's expiry window (Req 2.14).
    func start(interval: TimeInterval = 1.0) {
        normalInterval = interval
        let t = DispatchSource.makeTimerSource(queue: timerQueue)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in
            self?.timerFired()
        }
        t.resume()
        timer = t
        os_log("RtcpSender: started (interval=%.2fs)", log: log, type: .info, interval)
    }

    /// Cancels the timer immediately. Safe to call multiple times. (Req 3.3)
    func stop() {
        timer?.cancel()
        timer = nil
        os_log("RtcpSender: stopped", log: log, type: .info)
    }

    // MARK: - Timer Logic

    /// Called on every timer tick. Checks for stall condition and sends an RR.
    /// When no RTP packets have arrived for longer than `stallThreshold`,
    /// switches to a faster 250ms interval to aggressively signal the server
    /// that we are alive and ready to receive. When packets resume,
    /// `updateStats()` switches back to the normal interval.
    private func timerFired() {
        // Check for stall: if we have received at least one RTP packet and
        // the time since the last one exceeds the threshold, enter stall mode.
        if lastRtpArrivalTime > 0 && !isInStallMode {
            let elapsed = ProcessInfo.processInfo.systemUptime - lastRtpArrivalTime
            if elapsed > RtcpSender.stallThreshold {
                isInStallMode = true
                rescheduleTimer(interval: RtcpSender.stallInterval)
                os_log("RtcpSender: stall detected (%.1fs since last RTP), switching to %.0fms interval",
                       log: log, type: .info, elapsed, RtcpSender.stallInterval * 1000)
            }
        }

        sendReceiverReport()
    }

    /// Replaces the current timer with one at the new interval.
    /// Must be called on `timerQueue`.
    private func rescheduleTimer(interval: TimeInterval) {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: timerQueue)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in
            self?.timerFired()
        }
        t.resume()
        timer = t
    }

    // MARK: - Packet Construction and Send

    /// Builds an RTCP Receiver Report packet, wraps it in a TCP interleaved
    /// frame (or sends raw over UDP), and writes it via the transport.
    private func sendReceiverReport() {
        // Skip this tick if a previous send is still in flight
        guard !isSending else {
            os_log("RtcpSender: previous send still in flight, skipping tick", log: log, type: .debug)
            return
        }
        isSending = true
        rrSentCount += 1

        let rtcpPacket = buildReceiverReport(stats: stats)

        // Capture diagnostic values before the async send
        let diagSeq = stats.highestSeq
        let diagJitter = UInt32(min(jitter, Double(UInt32.max)))
        let diagLsr = lastSrNtpMiddle32
        let diagStall = isInStallMode
        let diagRrCount = rrSentCount
        let diagSrCount = srCount
        let diagPktCount = stats.packetCount

        // UDP path: send raw RTCP packet, no interleaved framing
        if let udpSend = udpSendHandler {
            udpSend(rtcpPacket)
            isSending = false
            if diagStall {
                os_log("RtcpSender: sent RR [STALL] seq=%u pkts=%u jitter=%u lsr=0x%08x rr#%u sr#%u",
                       log: log, type: .info,
                       diagSeq, diagPktCount, diagJitter, diagLsr, diagRrCount, diagSrCount)
            } else {
                os_log("RtcpSender: sent RR seq=%u pkts=%u jitter=%u lsr=0x%08x",
                       log: log, type: .debug,
                       diagSeq, diagPktCount, diagJitter, diagLsr)
            }
            return
        }

        // TCP path: wrap in interleaved frame
        let frame = wrapInInterleavedFrame(channel: 1, payload: rtcpPacket)

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.transport.send(data: frame)
                self.timerQueue.sync { self.isSending = false }
                if diagStall {
                    os_log("RtcpSender: sent RR [STALL] seq=%u pkts=%u jitter=%u lsr=0x%08x rr#%u sr#%u",
                           log: self.log, type: .info,
                           diagSeq, diagPktCount, diagJitter, diagLsr, diagRrCount, diagSrCount)
                } else {
                    os_log("RtcpSender: sent RR seq=%u pkts=%u jitter=%u lsr=0x%08x",
                           log: self.log, type: .debug,
                           diagSeq, diagPktCount, diagJitter, diagLsr)
                }
            } catch {
                os_log("RtcpSender: write error — %{public}@", log: self.log, type: .error,
                       error.localizedDescription)
                self.stop()
                self.timerQueue.sync { self.isSending = false }
                self.onError(error)
            }
        }
    }

    // MARK: - RTCP Packet Builder

    /// Builds a 32-byte RTCP Receiver Report packet. (Req 3.2)
    ///
    /// Computes real fraction lost, interarrival jitter, LSR, and DLSR per
    /// RFC 3550 §6.4.1 so the server's rate control sees a well-behaved
    /// receiver. The Bambu H2C firmware appears to throttle streams when
    /// these fields are all zero.
    private func buildReceiverReport(stats: RtpStats) -> Data {
        var data = Data(capacity: 32)

        // Header byte 0: V=2 P=0 RC=1  →  0b10_0_00001 = 0x81
        data.append(0x81)
        // Header byte 1: PT=201 (Receiver Report)
        data.append(201)
        // Header bytes 2-3: length = 7  (total 32 bytes / 4 - 1)
        data.appendUInt16BE(7)

        // SSRC of packet sender (we are the receiver — random per RFC 3550 §6.4.2)
        data.appendUInt32BE(receiverSsrc)

        // --- Report block (24 bytes) ---

        // SSRC of source
        data.appendUInt32BE(stats.ssrc)

        // Fraction lost (RFC 3550 §6.4.1):
        // fraction = (expected_interval - received_interval) / expected_interval * 256
        var fractionLost: UInt8 = 0
        if hasLostBaseline {
            let expectedInterval = Int64(stats.highestSeq) - Int64(prevHighestSeq)
            let receivedInterval = Int64(stats.packetCount) - Int64(prevPacketCount)
            if expectedInterval > 0 && receivedInterval < expectedInterval {
                let lost = expectedInterval - receivedInterval
                fractionLost = UInt8(min(255, (lost * 256) / expectedInterval))
            }
        }
        prevHighestSeq = stats.highestSeq
        prevPacketCount = stats.packetCount
        hasLostBaseline = true

        // Fraction lost (1 byte) | Cumulative packets lost (3 bytes)
        // Cumulative lost = expected - received (clamped to 24-bit signed)
        data.append(fractionLost)
        // Cumulative lost: total expected packets minus total received.
        // expected = highestSeq - initialSeq + 1, received = packetCount
        var cumulativeLost: Int32 = 0
        if hasInitialSeq {
            let expected = Int64(stats.highestSeq) - Int64(initialHighestSeq) + 1
            let lost = expected - Int64(stats.packetCount)
            // Clamp to 24-bit signed range (-8388608 to 8388607)
            cumulativeLost = Int32(clamping: max(-8_388_608, min(8_388_607, lost)))
        }
        // Encode as 24-bit signed big-endian
        let clBytes = UInt32(bitPattern: cumulativeLost)
        data.append(UInt8((clBytes >> 16) & 0xFF))
        data.append(UInt8((clBytes >> 8) & 0xFF))
        data.append(UInt8(clBytes & 0xFF))

        // Extended highest sequence number received
        data.appendUInt32BE(stats.highestSeq)

        // Interarrival jitter (in RTP timestamp units, RFC 3550 §6.4.1)
        let jitterValue = UInt32(min(jitter, Double(UInt32.max)))
        data.appendUInt32BE(jitterValue)

        // LSR — middle 32 bits of NTP timestamp from last SR (0 if no SR received)
        data.appendUInt32BE(lastSrNtpMiddle32)

        // DLSR — delay since last SR in 1/65536 second units
        var dlsr: UInt32 = 0
        if lastSrNtpMiddle32 != 0 && lastSrArrivalTime > 0 {
            let delaySec = ProcessInfo.processInfo.systemUptime - lastSrArrivalTime
            if delaySec > 0 && delaySec < 65536 {
                dlsr = UInt32(delaySec * 65536.0)
            }
        }
        data.appendUInt32BE(dlsr)

        return data
    }

    // MARK: - Testing Shims

    /// Exposes `buildReceiverReport` for unit tests.
    /// Reads stats synchronously on `timerQueue` to match production access pattern.
    func buildReceiverReportForTesting() -> Data {
        return timerQueue.sync {
            buildReceiverReport(stats: stats)
        }
    }

    // MARK: - TCP Interleaved Frame Wrapper

    /// Wraps `payload` in a TCP interleaved frame header:
    ///   [0x24, channel, length_hi, length_lo, ...payload...]
    private func wrapInInterleavedFrame(channel: UInt8, payload: Data) -> Data {
        var frame = Data(capacity: 4 + payload.count)
        frame.append(0x24)                          // magic byte '$'
        frame.append(channel)                       // channel number
        frame.appendUInt16BE(UInt16(payload.count)) // payload length
        frame.append(contentsOf: payload)
        return frame
    }
}

// MARK: - Data helpers

private extension Data {
    mutating func appendUInt16BE(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}
