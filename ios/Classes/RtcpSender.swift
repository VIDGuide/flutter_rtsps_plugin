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
///     SSRC of packet sender (4 bytes) — fixed 0 (we are the receiver)
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

    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "com.pandawatch.flutter_rtsps_plugin.rtcp")

    /// Guards against overlapping sends if a send takes longer than the 1-second interval.
    private var isSending = false

    /// Most recent RTP statistics snapshot, updated by `updateStats(_:)`.
    private var stats = RtpStats(ssrc: 0, highestSeq: 0, packetCount: 0, octetCount: 0)

    private let log = OSLog(subsystem: "com.pandawatch.flutter_rtsps_plugin", category: "RtcpSender")

    // MARK: - Init

    /// - Parameters:
    ///   - transport: A connected `RtspTransport` in the streaming state.
    ///   - onError: Called on the timer queue when a write error occurs.
    ///              The caller should initiate teardown in response. (Req 3.4)
    init(transport: RtspTransport, onError: @escaping (Error) -> Void) {
        self.transport = transport
        self.onError = onError
    }

    // MARK: - Stats Update

    /// Updates the RTP statistics used to populate the next Receiver Report.
    /// Called by `RtpDemuxer`'s `onRtpStats` callback. (Req 3.2)
    func updateStats(_ stats: RtpStats) {
        self.stats = stats
    }

    // MARK: - Lifecycle

    /// Creates and starts a `DispatchSourceTimer` that fires every 1 second
    /// on a background queue. (Req 3.1)
    func start() {
        let t = DispatchSource.makeTimerSource(queue: timerQueue)
        t.schedule(deadline: .now() + 1, repeating: 1.0)
        t.setEventHandler { [weak self] in
            self?.sendReceiverReport()
        }
        t.resume()
        timer = t
        os_log("RtcpSender: started", log: log, type: .info)
    }

    /// Cancels the timer immediately. Safe to call multiple times. (Req 3.3)
    func stop() {
        timer?.cancel()
        timer = nil
        os_log("RtcpSender: stopped", log: log, type: .info)
    }

    // MARK: - Packet Construction and Send

    /// Builds an RTCP Receiver Report packet, wraps it in a TCP interleaved
    /// frame, and writes it via the transport.
    private func sendReceiverReport() {
        // Skip this tick if a previous send is still in flight
        guard !isSending else {
            os_log("RtcpSender: previous send still in flight, skipping tick", log: log, type: .debug)
            return
        }
        isSending = true

        let rtcpPacket = buildReceiverReport(stats: stats)
        let frame = wrapInInterleavedFrame(channel: 1, payload: rtcpPacket)

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.transport.send(data: frame)
                // Clear the flag back on timerQueue to stay on the same executor
                // that set it, avoiding any ordering ambiguity.
                self.timerQueue.async { self.isSending = false }
                os_log("RtcpSender: sent RR (ssrc=%u, seq=%u)",
                       log: self.log, type: .debug,
                       self.stats.ssrc, self.stats.highestSeq)
            } catch {
                os_log("RtcpSender: write error — %{public}@", log: self.log, type: .error,
                       error.localizedDescription)
                // Stop the timer before propagating the error (Req 3.4)
                self.stop()
                self.timerQueue.async { self.isSending = false }
                self.onError(error)
            }
        }
    }

    // MARK: - RTCP Packet Builder

    /// Builds a 32-byte RTCP Receiver Report packet. (Req 3.2)
    ///
    /// Fraction lost, jitter, LSR, and DLSR are all set to 0 for simplicity.
    private func buildReceiverReport(stats: RtpStats) -> Data {
        var data = Data(capacity: 32)

        // Header byte 0: V=2 P=0 RC=1  →  0b10_0_00001 = 0x81
        data.append(0x81)
        // Header byte 1: PT=201 (Receiver Report)
        data.append(201)
        // Header bytes 2-3: length = 7  (total 32 bytes / 4 - 1)
        data.appendUInt16BE(7)

        // SSRC of packet sender (we are the receiver — use 0)
        data.appendUInt32BE(0)

        // --- Report block (24 bytes) ---

        // SSRC of source
        data.appendUInt32BE(stats.ssrc)

        // Fraction lost (1 byte) | Cumulative packets lost (3 bytes) — both 0
        data.append(0x00) // fraction lost
        data.append(0x00) // cumulative lost (MSB)
        data.append(0x00)
        data.append(0x00) // cumulative lost (LSB)

        // Extended highest sequence number received
        data.appendUInt32BE(stats.highestSeq)

        // Interarrival jitter — 0
        data.appendUInt32BE(0)

        // LSR (last SR timestamp) — 0 (no SR received)
        data.appendUInt32BE(0)

        // DLSR (delay since last SR) — 0
        data.appendUInt32BE(0)

        return data
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
