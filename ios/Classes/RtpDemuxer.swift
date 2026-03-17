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
    /// Lock protecting reads/writes of `running` across the read-loop Task
    /// and callers of `stop()` from arbitrary threads (Req 2.3).
    private let runLock = NSLock()

    /// FU-A reassembly buffer. Holds the reconstructed NAL header byte followed
    /// by accumulated fragment payloads. (Req 2.7)
    private var fuaBuffer: Data?

    /// The sequence number of the last RTP packet processed, used to detect gaps
    /// within a FU-A reassembly sequence.
    private var lastSeq: UInt32? = nil

    /// Number of 16-bit sequence number wraparound cycles observed, used to
    /// compute the extended highest sequence number per RFC 3550 (Defect 1.28).
    private var seqCycles: UInt32 = 0

    /// Maximum size of a reassembled FU-A NAL unit (2 MB). Buffers exceeding
    /// this are discarded to prevent unbounded memory growth on bad streams.
    private static let maxFuaBufferSize = 2 * 1024 * 1024

    /// Running RTP statistics forwarded to RtcpSender.
    private var stats = RtpStats(ssrc: 0, highestSeq: 0, packetCount: 0, octetCount: 0)

    private let log = OSLog(subsystem: "com.pandawatch.flutter_rtsps_plugin", category: "RtpDemuxer")

    // MARK: - Init

    /// - Parameter transport: A connected `RtspTransport` that has already
    ///   completed the RTSP handshake and is now in the streaming state.
    init(transport: RtspTransport) {
        self.transport = transport
    }

    // MARK: - Seed Data

    /// Prepends leftover bytes from the RTSP handshake so they are processed
    /// at the start of the read loop instead of being lost (Defect 1.12).
    ///
    /// Must be called BEFORE `start()`.
    func seedData(_ data: Data) {
        seedBuffer = data
    }

    /// Bytes seeded from the handshake lookahead, consumed at the start of the read loop.
    private var seedBuffer: Data?

    // MARK: - Lifecycle

    /// Launches a Swift `Task` that runs the read loop until `stop()` is called
    /// or the transport closes.
    func start() {
        runLock.lock()
        running = true
        runLock.unlock()
        Task { [weak self] in
            await self?.readLoop()
        }
    }

    /// Signals the read loop to exit after the current iteration.
    /// Clears reassembly state so a subsequent `start()` begins fresh (Req 2.22).
    func stop() {
        runLock.lock()
        running = false
        fuaBuffer = nil
        lastSeq = nil
        seqCycles = 0
        seedBuffer = nil
        runLock.unlock()
    }

    // MARK: - Read Loop

    private func readLoop() async {
        // Consume any seed data from the handshake lookahead (Defect 1.12).
        // These bytes are prepended to the stream so the first RTP packets
        // are not lost.
        var pendingSeed: Data? = nil
        runLock.lock()
        pendingSeed = seedBuffer
        seedBuffer = nil
        runLock.unlock()

        while true {
            runLock.lock()
            let isRunning = running
            runLock.unlock()
            guard isRunning else { break }

            do {
                // Read the 4-byte interleaved frame header: $ | channel | length(2)
                let header: Data
                if let seed = pendingSeed, seed.count >= 4 {
                    header = seed.prefix(4)
                    let remaining = seed.dropFirst(4)
                    pendingSeed = remaining.isEmpty ? nil : Data(remaining)
                } else {
                    // If seed has < 4 bytes, prepend them to the next transport read
                    if let seed = pendingSeed, !seed.isEmpty {
                        var combined = seed
                        let chunk = try await transport.receive(minimumLength: 1, maximumLength: 4 - seed.count)
                        combined.append(chunk)
                        pendingSeed = nil
                        if combined.count < 4 {
                            let more = try await transport.receive(minimumLength: 4 - combined.count, maximumLength: 4 - combined.count)
                            combined.append(more)
                        }
                        header = combined.prefix(4)
                        if combined.count > 4 {
                            pendingSeed = Data(combined.dropFirst(4))
                        }
                    } else {
                        header = try await transport.receive(minimumLength: 4, maximumLength: 4)
                    }
                }
                guard header.count == 4 else { continue }

                // Validate magic byte (Req 2.1)
                guard header[0] == 0x24 else {
                    os_log("RtpDemuxer: unexpected byte 0x%02x, expected 0x24", log: log, type: .error, header[0])
                    continue
                }

                let channel = header[1]
                let length = (UInt16(header[2]) << 8) | UInt16(header[3])

                // Discard zero-length frames
                if length == 0 {
                    continue
                }

                // Read the payload
                let payload: Data
                if let seed = pendingSeed, !seed.isEmpty {
                    if seed.count >= Int(length) {
                        payload = Data(seed.prefix(Int(length)))
                        let remaining = seed.dropFirst(Int(length))
                        pendingSeed = remaining.isEmpty ? nil : Data(remaining)
                    } else {
                        var combined = seed
                        pendingSeed = nil
                        let needed = Int(length) - combined.count
                        let chunk = try await transport.receive(
                            minimumLength: needed,
                            maximumLength: needed
                        )
                        combined.append(chunk)
                        payload = combined
                    }
                } else {
                    payload = try await transport.receive(
                        minimumLength: Int(length),
                        maximumLength: Int(length)
                    )
                }

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
                runLock.lock()
                running = false
                runLock.unlock()
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

        // Detect 16-bit sequence number wraparound (Defect 1.28)
        if let last = lastSeq {
            let lastLow = last & 0xFFFF
            if seqNum < lastLow && (lastLow - seqNum) > 0x8000 {
                seqCycles += 1
            }
        }

        stats.highestSeq = (seqCycles << 16) | seqNum
        stats.packetCount += 1
        stats.octetCount += UInt32(payload.count)
        onRtpStats?(stats)

        // Detect sequence number discontinuity — if a gap is detected while
        // reassembling a FU-A unit, discard the stale buffer so we don't
        // forward a corrupt NAL unit to the decoder.
        if let last = lastSeq {
            let expected = (last + 1) & 0xFFFF
            if seqNum != expected && fuaBuffer != nil {
                os_log("RtpDemuxer: seq gap detected (%u → %u), discarding FU-A buffer",
                       log: log, type: .default, last, seqNum)
                fuaBuffer = nil
            }
        }
        lastSeq = seqNum

        // Dispatch NAL unit extraction
        extractNalUnit(from: Data(payload), markerBit: markerBit)
    }

    // MARK: - NAL Unit Extraction

    /// Extracts a NAL unit from the RTP payload, handling FU-A fragmentation
    /// and STAP-A aggregation.
    private func extractNalUnit(from payload: Data, markerBit: Bool) {
        guard !payload.isEmpty else { return }

        let nalType = payload[0] & 0x1F

        switch nalType {
        case 28:
            // FU-A fragmented NAL unit (Req 2.7)
            handleFuA(payload: payload, markerBit: markerBit)
        case 24:
            // STAP-A: multiple NAL units aggregated in one RTP packet (RFC 6184 §5.7.1)
            // Format: STAP-A header (1 byte) | [size (2 bytes) | NAL unit] ...
            // The marker bit applies to the last NAL unit in the packet.
            handleStapA(payload: payload, markerBit: markerBit)
        default:
            // Single NAL unit packet — forward directly
            onNalUnit?(payload, markerBit)
        }
    }

    // MARK: - STAP-A Aggregation

    /// Handles STAP-A (NAL type 24) packets which carry multiple NAL units
    /// concatenated with 2-byte size prefixes (RFC 6184 §5.7.1).
    ///
    /// The marker bit signals end-of-access-unit and is forwarded only with
    /// the last NAL unit in the packet.
    private func handleStapA(payload: Data, markerBit: Bool) {
        // Skip the 1-byte STAP-A header
        var offset = 1
        var nalUnits: [Data] = []

        while offset + 2 <= payload.count {
            let size = Int(UInt16(payload[offset]) << 8 | UInt16(payload[offset + 1]))
            offset += 2
            guard size > 0, offset + size <= payload.count else {
                os_log("RtpDemuxer: STAP-A malformed at offset %d (size=%d, remaining=%d)",
                       log: log, type: .error, offset, size, payload.count - offset)
                break
            }
            nalUnits.append(Data(payload[offset ..< offset + size]))
            offset += size
        }

        guard !nalUnits.isEmpty else { return }

        for (i, nal) in nalUnits.enumerated() {
            let isLast = i == nalUnits.index(before: nalUnits.endIndex)
            // Only set the marker bit on the last NAL unit — it signals
            // end-of-access-unit to the decoder's accumulation logic.
            onNalUnit?(nal, isLast && markerBit)
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

            // Guard against unbounded accumulation on malformed/corrupt streams
            if buf.count > RtpDemuxer.maxFuaBufferSize {
                os_log("RtpDemuxer: FU-A buffer exceeded %d bytes, discarding",
                       log: log, type: .error, RtpDemuxer.maxFuaBufferSize)
                fuaBuffer = nil
                return
            }

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
