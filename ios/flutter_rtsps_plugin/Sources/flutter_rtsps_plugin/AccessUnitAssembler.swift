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
                return
            }

            pendingNalUnits.append(unit.data)

            if nalType == 5 {
                hasIDR = true
            }
        }

        // Marker bit → emit the complete access unit.
        if unit.isFrameComplete && !pendingNalUnits.isEmpty {
            let accessUnit = AccessUnit(
                nalUnits: pendingNalUnits,
                rtpTimestamp: unit.rtpTimestamp,
                sequenceNumber: unit.sequenceNumber,
                arrivalTime: ProcessInfo.processInfo.systemUptime,
                isIDR: hasIDR
            )
            pendingNalUnits.removeAll()
            hasIDR = false
            onAccessUnit?(accessUnit)
        }
    }

    /// Discard any partially accumulated frame. Called on stream reset.
    func flush() {
        pendingNalUnits.removeAll()
        hasIDR = false
    }
}
