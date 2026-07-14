import Foundation
import os.log

// MARK: - AccessUnitAssembler

/// Collects NAL units from `RtpDemuxer.onNalUnit` and emits complete
/// `AccessUnit` values when the RTP marker bit signals frame completion.
///
/// SPS (type 7) and PPS (type 8) parameter sets are forwarded via
/// `onParameterSet` and excluded from the assembled access unit.
///
/// Called synchronously from the demuxer's read loop — no separate queue.
///
/// - Requirements: 6.1, 6.2, 6.3
final class AccessUnitAssembler {

    // MARK: - Callbacks

    /// Called with each complete access unit (marker bit received).
    var onAccessUnit: ((AccessUnit) -> Void)?

    /// Called with SPS/PPS parameter sets for decoder init.
    /// Parameters: (raw NAL data, NAL type — 7 for SPS, 8 for PPS).
    var onParameterSet: ((Data, UInt8) -> Void)?

    // MARK: - Private State

    /// Accumulated non-parameter-set NAL payloads for the current frame.
    private var pendingNalUnits: [Data] = []

    /// Tracks whether any accumulated NAL is an IDR slice (type 5).
    private var hasIDR: Bool = false

    /// RTP timestamp of the frame currently being accumulated (the timestamp
    /// shared by all NALs of one access unit). Used to detect a frame boundary
    /// when the RTP timestamp changes — see `feedNalUnit`.
    private var pendingTimestamp: UInt32?

    /// Sequence number of the most recently accumulated NAL, used as the
    /// emitted access unit's sequence number when a frame is closed by a
    /// timestamp change rather than a marker bit.
    private var pendingSequenceNumber: UInt16 = 0

    /// Maximum NAL units before overflow discard (Req 6.3).
    private static let maxPendingNalUnits = 100

    private static let log = OSLog(
        subsystem: "com.pandawatch.rtsps",
        category: "AccessUnitAssembler"
    )

    // MARK: - Public API

    /// Feed a NAL unit from the demuxer. Accumulates until marker bit.
    ///
    /// - SPS (type 7) / PPS (type 8) are forwarded via `onParameterSet`
    ///   and **not** accumulated into the access unit.
    /// - STAP-A mixed content: parameter sets are forwarded while
    ///   non-parameter-set NALs from the same packet are accumulated.
    /// - When the marker bit is set the accumulated NALs are emitted
    ///   as a complete `AccessUnit`.
    /// - If 100+ NALs accumulate without a marker bit the buffer is
    ///   discarded and a warning is logged (Req 6.3).
    func feedNalUnit(_ unit: RtpNalUnit) {
        guard !unit.data.isEmpty else { return }

        let nalType = unit.data[unit.data.startIndex] & 0x1F

        // Timestamp-change frame boundary (RFC 6184 §5.1: all NALs of one access
        // unit share an RTP timestamp; a new timestamp begins a new access unit).
        // If we have NALs accumulated for a previous timestamp and this NAL
        // carries a different one, the previous frame is complete even though its
        // marker bit was never seen. This is a fallback for encoders that drop or
        // misplace the marker bit — observed on the Bambu H2C under load — which
        // would otherwise cause two frames to be merged into one malformed access
        // unit (corruption / stutter). It mirrors how FFmpeg's H.264 depacketizer
        // delimits frames. When marker bits are reliable this path never fires,
        // because the marker emit below already drained `pendingNalUnits`.
        if !pendingNalUnits.isEmpty,
           let pendingTs = pendingTimestamp,
           unit.rtpTimestamp != pendingTs {
            emitAccessUnit(timestamp: pendingTs, sequenceNumber: pendingSequenceNumber)
        }

        // Forward parameter sets via dedicated callback.
        if nalType == 7 || nalType == 8 {
            onParameterSet?(unit.data, nalType)
        }

        // Only accumulate non-parameter-set NALs into the access unit.
        if nalType != 7 && nalType != 8 {
            // Overflow guard — discard if we've hit the limit (Req 6.3).
            if pendingNalUnits.count >= Self.maxPendingNalUnits {
                os_log(
                    .fault,
                    log: Self.log,
                    "Overflow: %d NAL units accumulated without marker bit — discarding",
                    pendingNalUnits.count
                )
                pendingNalUnits.removeAll()
                hasIDR = false
                pendingTimestamp = nil
                return
            }

            pendingNalUnits.append(unit.data)
            pendingTimestamp = unit.rtpTimestamp
            pendingSequenceNumber = unit.sequenceNumber

            if nalType == 5 {
                hasIDR = true
            }
        }

        // Marker bit → emit the complete access unit.
        if unit.isFrameComplete && !pendingNalUnits.isEmpty {
            emitAccessUnit(timestamp: unit.rtpTimestamp, sequenceNumber: unit.sequenceNumber)
        }
    }

    /// Emits the accumulated NAL units as a complete `AccessUnit` and resets
    /// the pending state. No-op if nothing is accumulated.
    private func emitAccessUnit(timestamp: UInt32, sequenceNumber: UInt16) {
        guard !pendingNalUnits.isEmpty else { return }
        let accessUnit = AccessUnit(
            nalUnits: pendingNalUnits,
            rtpTimestamp: timestamp,
            sequenceNumber: sequenceNumber,
            arrivalTime: ProcessInfo.processInfo.systemUptime,
            isIDR: hasIDR
        )
        pendingNalUnits.removeAll()
        hasIDR = false
        pendingTimestamp = nil
        onAccessUnit?(accessUnit)
    }

    /// Discard any partially accumulated frame. Called on stream reset.
    func flush() {
        pendingNalUnits.removeAll()
        hasIDR = false
        pendingTimestamp = nil
    }
}
