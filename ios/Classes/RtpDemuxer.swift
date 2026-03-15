import Foundation
import os.log

// MARK: - RtpStats

/// Statistics tracked from received RTP packets, used by RtcpSender to build
/// Receiver Report packets (Req 3.2).
struct RtpStats {
    var ssrc: UInt32
    var highestSeq: UInt32
    var packetCount: UInt32
    var octetCount: UInt32
}

// MARK: - RtpDemuxer

/// Reads the TCP interleaved RTP/RTCP byte stream from an `RtspTransport` and
/// dispatches NAL units and RTCP packets to their respective consumers.
///
/// TCP interleaved framing (RFC 2326 §10.12):
///   0x24  |  channel (1 byte)  |  length (2 bytes, big-endian)  |  payload
///
/// Channel 0 → RTP  → H264Decoder callback (Req 2.2)
/// Channel 1 → RTCP → RtcpSender callback  (Req 2.3)
final class RtpDemuxer {

    // MARK: - Callbacks

    /// Called with each extracted NAL unit and a flag indicating whether the
    /// RTP marker bit was set (i.e. the access unit / frame is complete).
    /// (Req 2.4, 2.5, 2.7)
    var onNalUnit: ((Data, Bool) -> Void)?

    /// Called with each raw RTCP packet payload. (Req 2.3)
    var onRtcpPacket: ((Data) -> Void)?

    /// Called after each RTP packet is processed with updated statistics.
    /// Used by RtcpSender to populate Receiver Report fields. (Req 3.2)
    var onRtpStats: ((RtpStats) -> Void)?

    // MARK: - Private state

    private let transport: RtspTransport
    private var running = false

    /// FU-A reassembly buffer. Holds the reconstructed NAL header byte followed
    /// by accumulated fragment payloads. (Req 2.7)
    private var fuaBuffer: Data?

    /// Running RTP statistics forwarded to RtcpSender.
    private var stats = RtpStats(ssrc: 0, highestSeq: 0, packetCount: 0, octetCount: 0)

    private let log = OSLog(subsystem: "com.pandawatch.flutter_rtsps_plugin", category: "RtpDemuxer")

    // MARK: - Init

    /// - Parameter transport: A connected `RtspTransport` that has already
    ///   completed the RTSP handshake and is now in the streaming state.
    init(transport: RtspTransport) {
        self.transport = transport
    }

    // MARK: - Lifecycle

    /// Launches a Swift `Task` that runs the read loop until `stop()` is called
    /// or the transport closes.
    func start() {
        running = true
        Task { [weak self] in
            await self?.readLoop()
        }
    }

    /// Signals the read loop to exit after the current iteration.
    func stop() {
        running = false
    }

    // MARK: - Read Loop

    private func readLoop() async {
        while running {
            do {
                // Read the 4-byte interleaved frame header: $ | channel | length(2)
                let header = try await transport.receive(minimumLength: 4, maximumLength: 4)
                guard header.count == 4 else { continue }

                // Validate magic byte (Req 2.1)
                guard header[0] == 0x24 else {
                    os_log("RtpDemuxer: unexpected byte 0x%02x, expected 0x24", log: log, type: .error, header[0])
                    continue
                }

                let channel = header[1]
                let length = (UInt16(header[2]) << 8) | UInt16(header[3])

                // Discard oversized frames without terminating the stream (Req 2.6)
                if length > 65535 {
                    os_log("RtpDemuxer: frame length %u exceeds 65535, discarding", log: log, type: .default, length)
                    continue
                }

                // Read the payload
                let payload = try await transport.receive(
                    minimumLength: Int(length),
                    maximumLength: Int(length)
                )

                switch channel {
                case 0:
                    processRtpPacket(payload)
                case 1:
                    onRtcpPacket?(payload)
                default:
                    os_log("RtpDemuxer: unknown channel %u, discarding", log: log, type: .default, channel)
                }

            } catch {
                // Transport closed or errored — exit the loop cleanly (Req: graceful close)
                os_log("RtpDemuxer: read loop exiting: %{public}@", log: log, type: .info, error.localizedDescription)
                running = false
            }
        }
    }

    // MARK: - RTP Packet Processing

    /// Parses the RTP header, extracts the NAL unit payload, and handles FU-A
    /// reassembly. (Req 2.4, 2.5, 2.7)
    private func processRtpPacket(_ packet: Data) {
        guard packet.count >= 12 else {
            os_log("RtpDemuxer: RTP packet too short (%d bytes)", log: log, type: .error, packet.count)
            return
        }

        // Byte 0: V(2) P(1) X(1) CC(4)
        let byte0 = packet[0]
        let hasExtension = (byte0 & 0x10) != 0
        let csrcCount = Int(byte0 & 0x0F)

        // Byte 1: M(1) PT(7)
        let byte1 = packet[1]
        let markerBit = (byte1 & 0x80) != 0

        // Bytes 2-3: sequence number
        let seqNum = (UInt32(packet[2]) << 8) | UInt32(packet[3])

        // Bytes 8-11: SSRC
        let ssrc = (UInt32(packet[8]) << 24) | (UInt32(packet[9]) << 16)
                 | (UInt32(packet[10]) << 8)  |  UInt32(packet[11])

        // Payload offset: fixed 12-byte header + CSRC list
        var offset = 12 + csrcCount * 4

        // Skip RTP header extension if X bit is set
        if hasExtension {
            // Extension: 2-byte profile + 2-byte length (in 32-bit words)
            guard packet.count >= offset + 4 else { return }
            let extLen = Int((UInt16(packet[offset + 2]) << 8) | UInt16(packet[offset + 3]))
            offset += 4 + extLen * 4
        }

        guard offset < packet.count else {
            os_log("RtpDemuxer: RTP payload offset %d beyond packet length %d", log: log, type: .error, offset, packet.count)
            return
        }

        let payload = packet[offset...]

        // Update statistics
        stats.ssrc = ssrc
        stats.highestSeq = seqNum
        stats.packetCount += 1
        stats.octetCount += UInt32(payload.count)
        onRtpStats?(stats)

        // Dispatch NAL unit extraction
        extractNalUnit(from: Data(payload), markerBit: markerBit)
    }

    // MARK: - NAL Unit Extraction

    /// Extracts a NAL unit from the RTP payload, handling FU-A fragmentation.
    private func extractNalUnit(from payload: Data, markerBit: Bool) {
        guard !payload.isEmpty else { return }

        let nalType = payload[0] & 0x1F

        if nalType == 28 {
            // FU-A fragmented NAL unit (Req 2.7)
            handleFuA(payload: payload, markerBit: markerBit)
        } else {
            // Single NAL unit packet — forward directly
            onNalUnit?(payload, markerBit)
        }
    }

    // MARK: - Testing Shims

    /// Exposes `processRtpPacket` for unit tests that construct raw RTP bytes.
    func processRtpPacketForTesting(_ packet: Data) {
        processRtpPacket(packet)
    }

    /// Exposes the channel-dispatch logic for unit tests.
    func dispatchPayloadForTesting(channel: UInt8, payload: Data) {
        switch channel {
        case 0:
            processRtpPacket(payload)
        case 1:
            onRtcpPacket?(payload)
        default:
            break
        }
    }

    // MARK: - FU-A Reassembly

    /// Handles FU-A (NAL type 28) fragmentation reassembly.
    ///
    /// FU indicator byte: forbidden_zero(1) NRI(2) type=28(5)
    /// FU header byte:    S(1) E(1) R(1) nal_type(5)
    private func handleFuA(payload: Data, markerBit: Bool) {
        guard payload.count >= 2 else {
            os_log("RtpDemuxer: FU-A packet too short", log: log, type: .error)
            return
        }

        let fuIndicator = payload[0]  // NRI bits live here
        let fuHeader = payload[1]
        let isStart = (fuHeader & 0x80) != 0
        let isEnd   = (fuHeader & 0x40) != 0
        let nalType = fuHeader & 0x1F

        // Fragment payload: everything after the 2-byte FU header
        let fragment = payload[2...]

        if isStart {
            // Reconstruct the NAL header: (FU_indicator & 0xE0) | nal_type
            let nalHeader = (fuIndicator & 0xE0) | nalType
            fuaBuffer = Data([nalHeader])
            fuaBuffer?.append(contentsOf: fragment)
        } else if var buf = fuaBuffer {
            buf.append(contentsOf: fragment)
            fuaBuffer = buf

            if isEnd {
                // Complete NAL unit assembled — forward it
                onNalUnit?(fuaBuffer!, markerBit)
                fuaBuffer = nil
            }
        } else {
            // Middle/end fragment arrived without a start — discard
            os_log("RtpDemuxer: FU-A fragment received without start, discarding", log: log, type: .default)
        }
    }
}
