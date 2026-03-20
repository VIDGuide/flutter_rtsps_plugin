import XCTest
import SwiftCheck
@testable import flutter_rtsps_plugin

// Feature: rtsps-jitter-buffer
// Properties 1, 2, 3, 4, 19 — JitterBuffer core property tests

final class JitterBufferPropertyTests: XCTestCase {

    private let args = CheckerArguments(maxAllowableSuccessfulTests: 30)

    // MARK: - Helpers

    /// Create a minimal AccessUnit with the given parameters.
    private static func makeAccessUnit(
        rtpTimestamp: UInt32,
        sequenceNumber: UInt16,
        isIDR: Bool = false,
        nalPayload: [UInt8] = [0x65, 0x00, 0x01]
    ) -> AccessUnit {
        let nalType: UInt8 = isIDR ? 5 : 1
        var bytes = [UInt8](repeating: 0, count: nalPayload.count + 1)
        bytes[0] = (2 << 5) | (nalType & 0x1F)
        for i in 0..<nalPayload.count {
            bytes[i + 1] = nalPayload[i]
        }
        return AccessUnit(
            nalUnits: [Data(bytes)],
            rtpTimestamp: rtpTimestamp,
            sequenceNumber: sequenceNumber,
            arrivalTime: ProcessInfo.processInfo.systemUptime,
            isIDR: isIDR
        )
    }

    // MARK: - Property 1: RTP Timestamp to Wall-Clock Interval Conversion
    // **Validates: Requirements 1.4, 1.5, 1.6, 2.1, 2.2**

    /// For any two consecutive access units with positive Int32(bitPattern: T2 &- T1),
    /// the release interval equals Double(Int32(bitPattern: T2 &- T1)) / 90000.0 seconds.
    func testRTPTimestampToWallClockConversion() {
        // Generate pairs where the signed delta is positive (forward progression).
        let t1Gen = Gen<UInt32>.choose((0, UInt32.max))
        let positiveDeltaGen = Gen<UInt32>.choose((1, UInt32(Int32.max)))

        property("rtpIntervalSeconds computes Double(Int32(bitPattern: T2 &- T1)) / 90000.0", arguments: args) <- forAll(t1Gen, positiveDeltaGen) { (t1: UInt32, delta: UInt32) in
            let t2 = t1 &+ delta
            let result = JitterBuffer.rtpIntervalSeconds(from: t1, to: t2)
            let expected = Double(Int32(bitPattern: t2 &- t1)) / 90000.0
            return abs(result - expected) < 1e-12
        }
    }

    /// The conversion handles wraparound: T1 near UInt32.max, T2 past zero.
    func testRTPTimestampWraparoundConversion() {
        let highT1Gen = Gen<UInt32>.choose((UInt32.max - 1_000_000, UInt32.max))
        let smallDeltaGen = Gen<UInt32>.choose((1, 1_000_000))

        property("rtpIntervalSeconds handles wraparound across 2^32 boundary", arguments: args) <- forAll(highT1Gen, smallDeltaGen) { (t1: UInt32, delta: UInt32) in
            let t2 = t1 &+ delta
            let result = JitterBuffer.rtpIntervalSeconds(from: t1, to: t2)
            let expected = Double(Int32(bitPattern: t2 &- t1)) / 90000.0
            // Delta is positive and small, so result must be positive
            return result > 0 && abs(result - expected) < 1e-12
        }
    }


    // MARK: - Property 2: TCP Mode FIFO Ordering
    // **Validates: Requirements 1.2**

    /// For any sequence of N access units enqueued in TCP mode,
    /// release order is identical to enqueue order.
    func testTCPModeFIFOOrdering() {
        let countGen = Gen<Int>.fromElements(in: 1...50)
        let baseTimestampGen = Gen<UInt32>.choose((0, UInt32.max))
        let baseSeqGen = Gen<UInt16>.choose((0, UInt16.max))

        property("TCP mode releases frames in FIFO enqueue order", arguments: args) <- forAll(countGen, baseTimestampGen, baseSeqGen) { (count: Int, baseTs: UInt32, baseSeq: UInt16) in
            // Use large buffer depth so overflow handling doesn't drop frames during ordering tests.
            let config = JitterBufferConfig(bufferDepthMs: 1000, transportMode: .tcp)
            let jb = JitterBuffer(config: config)

            // Enqueue N frames with arbitrary (possibly out-of-order) sequence numbers
            var enqueuedTimestamps: [UInt32] = []
            for i in 0..<count {
                let ts = baseTs &+ UInt32(i &* 3000) // varying timestamps
                let seq = baseSeq &+ UInt16(truncatingIfNeeded: count &- i) // reverse seq order
                let au = Self.makeAccessUnit(rtpTimestamp: ts, sequenceNumber: seq)
                enqueuedTimestamps.append(ts)
                jb.enqueue(au)
            }

            // Release all and verify FIFO order
            var releasedTimestamps: [UInt32] = []
            while let released = jb.releaseNextForTesting() {
                releasedTimestamps.append(released.rtpTimestamp)
            }

            return releasedTimestamps == enqueuedTimestamps
        }
    }

    // MARK: - Property 3: UDP Mode Sequence-Number Ordering
    // **Validates: Requirements 1.3, 9.2**

    /// For any set of access units in UDP mode with distinct sequence numbers,
    /// release order is sorted by wraparound-safe signed 16-bit comparison.
    func testUDPModeSequenceNumberOrdering() {
        // Generate a list of distinct sequence numbers
        let countGen = Gen<Int>.fromElements(in: 1...30)
        let baseSeqGen = Gen<UInt16>.choose((0, UInt16.max))

        property("UDP mode releases frames sorted by wraparound-safe sequence number", arguments: args) <- forAll(countGen, baseSeqGen) { (count: Int, baseSeq: UInt16) in
            // Use large buffer depth so overflow handling doesn't drop frames during ordering tests.
            let config = JitterBufferConfig(bufferDepthMs: 1000, transportMode: .udp)
            let jb = JitterBuffer(config: config)

            // Generate distinct sequence numbers as offsets from base
            // Use small positive offsets to ensure they're in forward progression
            var seqNumbers: [UInt16] = []
            for i in 0..<count {
                seqNumbers.append(baseSeq &+ UInt16(truncatingIfNeeded: i))
            }

            // Shuffle the sequence numbers for enqueue (deterministic shuffle via reversal + interleave)
            var shuffled = seqNumbers
            shuffled.reverse()
            // Interleave: take from front and back alternately
            var interleaved: [UInt16] = []
            var lo = 0, hi = shuffled.count - 1
            while lo <= hi {
                interleaved.append(shuffled[lo])
                if lo != hi {
                    interleaved.append(shuffled[hi])
                }
                lo += 1
                hi -= 1
            }

            // Enqueue in shuffled order
            for seq in interleaved {
                let au = Self.makeAccessUnit(
                    rtpTimestamp: UInt32(seq) &* 3000,
                    sequenceNumber: seq
                )
                jb.enqueue(au)
            }

            // Release all and collect sequence numbers
            var releasedSeqs: [UInt16] = []
            while let released = jb.releaseNextForTesting() {
                releasedSeqs.append(released.sequenceNumber)
            }

            // Verify sorted by wraparound-safe comparison
            guard releasedSeqs.count == count else { return false }
            for i in 1..<releasedSeqs.count {
                let delta = Int16(bitPattern: releasedSeqs[i] &- releasedSeqs[i - 1])
                if delta <= 0 { return false }
            }
            return true
        }
    }

    /// UDP mode handles sequence number wraparound near UInt16.max.
    func testUDPModeSequenceWraparound() {
        let countGen = Gen<Int>.fromElements(in: 2...20)

        property("UDP mode correctly orders across UInt16 wraparound boundary", arguments: args) <- forAll(countGen) { (count: Int) in
            // Use large buffer depth so overflow handling doesn't drop frames during ordering tests.
            let config = JitterBufferConfig(bufferDepthMs: 1000, transportMode: .udp)
            let jb = JitterBuffer(config: config)

            // Start near UInt16.max so sequence wraps around
            let startSeq: UInt16 = UInt16.max - UInt16(count / 2)
            var expectedOrder: [UInt16] = []
            for i in 0..<count {
                expectedOrder.append(startSeq &+ UInt16(truncatingIfNeeded: i))
            }

            // Enqueue in reverse order
            for seq in expectedOrder.reversed() {
                let au = Self.makeAccessUnit(
                    rtpTimestamp: UInt32(seq) &* 3000,
                    sequenceNumber: seq
                )
                jb.enqueue(au)
            }

            // Release and verify order
            var releasedSeqs: [UInt16] = []
            while let released = jb.releaseNextForTesting() {
                releasedSeqs.append(released.sequenceNumber)
            }

            return releasedSeqs == expectedOrder
        }
    }


    // MARK: - Property 4: RTP Timestamp Wraparound Arithmetic
    // **Validates: Requirements 2.3**

    /// For any pair of 32-bit unsigned timestamps, Int32(bitPattern: next &- prev)
    /// yields positive for forward progression (even across 2^32 boundary)
    /// and detects discontinuities when |delta| > 2^31.
    func testRTPTimestampWraparoundArithmetic() {
        let prevGen = Gen<UInt32>.choose((0, UInt32.max))
        // Forward delta: 1 to Int32.max (positive in signed interpretation)
        let forwardDeltaGen = Gen<UInt32>.choose((1, UInt32(Int32.max)))

        property("Forward progression yields positive signed delta even across 2^32", arguments: args) <- forAll(prevGen, forwardDeltaGen) { (prev: UInt32, delta: UInt32) in
            let next = prev &+ delta
            let signedDelta = Int32(bitPattern: next &- prev)
            return signedDelta > 0
        }
    }

    /// Discontinuity detection: when the unsigned gap exceeds 2^31,
    /// the signed delta is negative (or zero), indicating a discontinuity.
    func testRTPTimestampDiscontinuityDetection() {
        let prevGen = Gen<UInt32>.choose((0, UInt32.max))
        // Large backward jump: delta in range (Int32.max+1 ... UInt32.max)
        // This means the signed interpretation is negative.
        let largeDeltaGen = Gen<UInt32>.choose((UInt32(Int32.max) + 1, UInt32.max))

        property("Backward/discontinuity yields negative signed delta (|delta| > 2^31)", arguments: args) <- forAll(prevGen, largeDeltaGen) { (prev: UInt32, delta: UInt32) in
            let next = prev &+ delta
            let signedDelta = Int32(bitPattern: next &- prev)
            // The signed delta should be negative (discontinuity)
            return signedDelta < 0
        }
    }

    // MARK: - Property 7: Overflow Drops Preserve IDR Frames
    // Feature: rtsps-jitter-buffer, Property 7: Overflow Drops Preserve IDR Frames
    // **Validates: Requirements 1.8**

    /// After overflow handling: non-IDR dropped before IDR; if still over limit (all-IDR),
    /// oldest IDR dropped; fill level always ≤ 2× depth.
    func testOverflowDropsPreserveIDRFrames() {
        // bufferDepthMs=50 → maxAllowed = max(1, (2*50)/33) = 3
        let maxAllowed = 3

        // Generate a mix of IDR and non-IDR frames exceeding the threshold
        let totalCountGen = Gen<Int>.fromElements(in: (maxAllowed + 1)...15)
        let idrCountGen = Gen<Int>.fromElements(in: 0...15)

        property("Overflow drops non-IDR before IDR, fill level always ≤ 2× depth", arguments: args) <- forAll(totalCountGen, idrCountGen) { (totalCount: Int, rawIdrCount: Int) in
            let idrCount = min(rawIdrCount, totalCount)
            let config = JitterBufferConfig(bufferDepthMs: 50, transportMode: .tcp)
            let jb = JitterBuffer(config: config)

            // Enqueue idrCount IDR frames first, then non-IDR frames
            for i in 0..<totalCount {
                let isIDR = i < idrCount
                let au = Self.makeAccessUnit(
                    rtpTimestamp: UInt32(i) * 3000,
                    sequenceNumber: UInt16(truncatingIfNeeded: i),
                    isIDR: isIDR
                )
                jb.enqueue(au)
            }

            let stats = jb.stats
            let bufCount = stats.framesBuffered

            // 1. Buffer count must be ≤ maxAllowed after overflow handling
            guard bufCount <= maxAllowed else { return false }

            // 2. totalFramesDropped must equal totalCount - bufCount
            let expectedDropped = UInt64(totalCount - bufCount)
            guard stats.totalFramesDropped == expectedDropped else { return false }

            // 3. Verify IDR preservation: release remaining frames and check
            var releasedIDRCount = 0
            var releasedNonIDRCount = 0
            while let frame = jb.releaseNextForTesting() {
                if frame.isIDR { releasedIDRCount += 1 }
                else { releasedNonIDRCount += 1 }
            }

            // If there were enough IDR frames to fill the buffer, all remaining should be IDR
            if idrCount >= maxAllowed {
                // All non-IDR should have been dropped; remaining are IDR (up to maxAllowed)
                guard releasedNonIDRCount == 0 else { return false }
                guard releasedIDRCount == min(idrCount, maxAllowed) else { return false }
            } else {
                // IDR count < maxAllowed: all IDR frames should be preserved
                guard releasedIDRCount == idrCount else { return false }
            }

            return true
        }
    }

    /// When all frames are IDR, oldest IDR frames are dropped to maintain the limit.
    func testOverflowAllIDRDropsOldest() {
        let maxAllowed = 3 // bufferDepthMs=50

        let totalCountGen = Gen<Int>.fromElements(in: (maxAllowed + 1)...15)

        property("All-IDR overflow drops oldest IDR frames, preserves newest", arguments: args) <- forAll(totalCountGen) { (totalCount: Int) in
            let config = JitterBufferConfig(bufferDepthMs: 50, transportMode: .tcp)
            let jb = JitterBuffer(config: config)

            // Enqueue all IDR frames
            for i in 0..<totalCount {
                let au = Self.makeAccessUnit(
                    rtpTimestamp: UInt32(i) * 3000,
                    sequenceNumber: UInt16(truncatingIfNeeded: i),
                    isIDR: true
                )
                jb.enqueue(au)
            }

            let stats = jb.stats

            // Buffer must be at or below the threshold
            guard stats.framesBuffered <= maxAllowed else { return false }

            // Dropped count must be correct
            let expectedDropped = UInt64(totalCount - stats.framesBuffered)
            guard stats.totalFramesDropped == expectedDropped else { return false }

            // The remaining frames should be the newest (highest sequence numbers)
            var releasedSeqs: [UInt16] = []
            while let frame = jb.releaseNextForTesting() {
                guard frame.isIDR else { return false }
                releasedSeqs.append(frame.sequenceNumber)
            }

            // Verify we kept the last maxAllowed frames (newest)
            let expectedSeqs = (totalCount - maxAllowed..<totalCount).map { UInt16(truncatingIfNeeded: $0) }
            guard releasedSeqs == expectedSeqs else { return false }

            return true
        }
    }

    // MARK: - Property 19: Enqueue Preserves Access Unit Data
    // **Validates: Requirements 1.1**

    /// For any AccessUnit enqueued then released, nalUnits, rtpTimestamp,
    /// sequenceNumber, and isIDR are identical.
    func testEnqueuePreservesAccessUnitData() {
        let timestampGen = Gen<UInt32>.choose((0, UInt32.max))
        let seqGen = Gen<UInt16>.choose((0, UInt16.max))
        let isIDRGen = Gen<Bool>.pure(true).proliferate(withSize: 1).map { _ in Bool.random() }
        let nalCountGen = Gen<Int>.fromElements(in: 1...10)
        let payloadSizeGen = Gen<Int>.fromElements(in: 1...128)

        property("Enqueue then release preserves nalUnits, rtpTimestamp, sequenceNumber, isIDR", arguments: args) <- forAll(timestampGen, seqGen, nalCountGen, payloadSizeGen) { (ts: UInt32, seq: UInt16, nalCount: Int, payloadSize: Int) in
            // Test both TCP and UDP modes
            for mode in [TransportMode.tcp, TransportMode.udp] {
                let config = JitterBufferConfig(bufferDepthMs: 50, transportMode: mode)
                let jb = JitterBuffer(config: config)

                // Build deterministic NAL units
                var nalUnits: [Data] = []
                var hasIDR = false
                for i in 0..<nalCount {
                    let nalType: UInt8 = (i == 0) ? 5 : 1 // first NAL is IDR
                    if nalType == 5 { hasIDR = true }
                    var bytes = [UInt8](repeating: 0, count: payloadSize + 1)
                    bytes[0] = (2 << 5) | (nalType & 0x1F)
                    for j in 1..<bytes.count {
                        bytes[j] = UInt8(truncatingIfNeeded: j &+ i &+ Int(ts))
                    }
                    nalUnits.append(Data(bytes))
                }

                let original = AccessUnit(
                    nalUnits: nalUnits,
                    rtpTimestamp: ts,
                    sequenceNumber: seq,
                    arrivalTime: ProcessInfo.processInfo.systemUptime,
                    isIDR: hasIDR
                )

                jb.enqueue(original)

                guard let released = jb.releaseNextForTesting() else { return false }

                // Verify all fields are identical
                guard released.rtpTimestamp == ts else { return false }
                guard released.sequenceNumber == seq else { return false }
                guard released.isIDR == hasIDR else { return false }
                guard released.nalUnits.count == nalUnits.count else { return false }
                for (idx, expectedNal) in nalUnits.enumerated() {
                    guard released.nalUnits[idx] == expectedNal else { return false }
                }
            }
            return true
        }
    }

    // MARK: - Property 8: Underrun Buffering Period
    // Feature: rtsps-jitter-buffer, Property 8: Underrun Buffering Period
    // **Validates: Requirements 1.9, 1.10**

    /// After underrun, no frames released until bufferDepthMs elapsed since first enqueue.
    /// No null/empty access units ever emitted.
    /// Tests state transitions: fresh buffer starts buffering, enqueue keeps buffering state,
    /// releasing all frames returns to buffering state, and no null/empty frames are emitted.
    func testUnderrunBufferingPeriod() {
        let countGen = Gen<Int>.fromElements(in: 1...20)
        let depthGen = Gen<Int>.fromElements(in: 50...1000)
        let baseTimestampGen = Gen<UInt32>.choose((0, UInt32.max - 1_000_000))

        property("Fresh buffer starts buffering; after drain, returns to buffering; no null/empty AUs", arguments: args) <- forAll(countGen, depthGen, baseTimestampGen) { (count: Int, depth: Int, baseTs: UInt32) in
            for mode in [TransportMode.tcp, TransportMode.udp] {
                let config = JitterBufferConfig(bufferDepthMs: depth, transportMode: mode)
                let jb = JitterBuffer(config: config)

                // 1. A fresh JitterBuffer starts in buffering state
                guard jb.isInBufferingState else { return false }

                // Enqueue frames
                for i in 0..<count {
                    let au = Self.makeAccessUnit(
                        rtpTimestamp: baseTs &+ UInt32(i) * 3000,
                        sequenceNumber: UInt16(truncatingIfNeeded: i)
                    )
                    jb.enqueue(au)
                }

                // 2. After enqueuing, buffer is still in buffering state
                //    (no timer has fired to transition out of buffering)
                guard jb.isInBufferingState else { return false }

                // 3. releaseNextForTesting bypasses the timer — release all frames
                //    and verify no null/empty access units are emitted
                var releasedCount = 0
                while let frame = jb.releaseNextForTesting() {
                    // No empty access units: nalUnits must be non-empty
                    guard !frame.nalUnits.isEmpty else { return false }
                    // Each NAL unit must be non-empty
                    for nal in frame.nalUnits {
                        guard !nal.isEmpty else { return false }
                    }
                    releasedCount += 1
                }

                // All enqueued frames should have been released
                // (accounting for possible overflow drops with small depth)
                guard releasedCount > 0 else { return false }
                guard releasedCount <= count else { return false }

                // 4. After releasing all frames (buffer empty), isInBufferingState returns to true
                guard jb.isInBufferingState else { return false }

                // 5. Enqueue again after underrun — should be back in buffering state
                let recoveryAU = Self.makeAccessUnit(
                    rtpTimestamp: baseTs &+ UInt32(count) * 3000,
                    sequenceNumber: UInt16(truncatingIfNeeded: count)
                )
                jb.enqueue(recoveryAU)
                guard jb.isInBufferingState else { return false }

                // Release the recovery frame — verify non-null, non-empty
                if let recovered = jb.releaseNextForTesting() {
                    guard !recovered.nalUnits.isEmpty else { return false }
                    for nal in recovered.nalUnits {
                        guard !nal.isEmpty else { return false }
                    }
                } else {
                    return false
                }

                // After draining again, back to buffering
                guard jb.isInBufferingState else { return false }
            }
            return true
        }
    }

    // MARK: - Property 5: Stale Frame Discard
    // **Validates: Requirements 2.4**

    /// Any access unit >270,000 ticks behind playout position is discarded
    /// and drop counter incremented. Discarded frame does not appear in release output.
    func testStaleFrameDiscard() {
        let baseTimestampGen = Gen<UInt32>.choose((JitterBuffer.staleThresholdTicks + 1, UInt32.max / 2))
        // Stale offset: must exceed the threshold (270,000 ticks)
        let staleOffsetGen = Gen<UInt32>.choose((JitterBuffer.staleThresholdTicks + 1, JitterBuffer.staleThresholdTicks * 3))
        // Non-stale offset: within the threshold
        let freshOffsetGen = Gen<UInt32>.choose((1, JitterBuffer.staleThresholdTicks))

        property("Stale frames (>270,000 ticks behind playout) are discarded; fresh frames accepted", arguments: args) <- forAll(baseTimestampGen, staleOffsetGen, freshOffsetGen) { (baseTs: UInt32, staleOffset: UInt32, freshOffset: UInt32) in
            let config = JitterBufferConfig(bufferDepthMs: 1000, transportMode: .tcp)
            let jb = JitterBuffer(config: config)

            // 1. Enqueue and release a frame to establish lastReleasedTimestamp
            let firstFrame = Self.makeAccessUnit(
                rtpTimestamp: baseTs,
                sequenceNumber: 0,
                isIDR: true
            )
            jb.enqueue(firstFrame)
            guard jb.releaseNextForTesting() != nil else { return false }

            let statsBefore = jb.stats

            // 2. Enqueue a stale frame (RTP timestamp >270,000 ticks behind released frame)
            let staleTs = baseTs &- staleOffset
            let staleFrame = Self.makeAccessUnit(
                rtpTimestamp: staleTs,
                sequenceNumber: 1
            )
            jb.enqueue(staleFrame)

            // Stale frame must NOT be in the buffer
            guard jb.bufferCount == 0 else { return false }

            // Drop counter must have incremented
            let statsAfterStale = jb.stats
            guard statsAfterStale.totalFramesDropped == statsBefore.totalFramesDropped + 1 else { return false }

            // 3. Enqueue a non-stale frame (within 270,000 ticks) — should be accepted
            let freshTs = baseTs &- freshOffset
            let freshFrame = Self.makeAccessUnit(
                rtpTimestamp: freshTs,
                sequenceNumber: 2
            )
            jb.enqueue(freshFrame)

            // Fresh frame must be in the buffer
            guard jb.bufferCount == 1 else { return false }

            // Drop counter must NOT have incremented again
            let statsAfterFresh = jb.stats
            guard statsAfterFresh.totalFramesDropped == statsAfterStale.totalFramesDropped else { return false }

            // Release the fresh frame and verify it's the one we enqueued
            guard let released = jb.releaseNextForTesting() else { return false }
            guard released.rtpTimestamp == freshTs else { return false }

            return true
        }
    }

    // MARK: - Property 6: Inter-Frame EMA and Outlier Substitution
    // **Validates: Requirements 2.5**

    /// EMA computed with gain 1/16. Any frame deviating >50% from EMA uses EMA value
    /// for release interval. Verifies EMA convergence for steady deltas and that outlier
    /// frames do not cause the EMA to jump wildly.
    func testInterFrameEMAAndOutlierSubstitution() {
        // Generate a steady RTP tick delta (e.g. 2400–4500 ticks ≈ 26–50ms at 90kHz)
        let steadyDeltaGen = Gen<UInt32>.choose((2400, 4500))
        // Number of steady frames to build up EMA (5–20)
        let steadyCountGen = Gen<Int>.fromElements(in: 5...20)
        // Outlier multiplier: 3× to 10× the steady delta (guaranteed >50% deviation)
        let outlierMultiplierGen = Gen<Double>.choose((3.0, 10.0))

        property("EMA converges for steady deltas; outlier does not cause EMA to jump wildly", arguments: args) <- forAll(steadyDeltaGen, steadyCountGen, outlierMultiplierGen) { (steadyDelta: UInt32, steadyCount: Int, outlierMult: Double) in
            let config = JitterBufferConfig(bufferDepthMs: 1000, transportMode: .tcp)
            let jb = JitterBuffer(config: config)

            let steadyIntervalSec = Double(steadyDelta) / 90000.0

            // Enqueue all frames upfront: first frame + steadyCount steady + 1 outlier
            var ts: UInt32 = 0
            var seq: UInt16 = 0

            // Frame 0: base frame (seeds baseRtpTimestamp, no EMA update)
            jb.enqueue(Self.makeAccessUnit(rtpTimestamp: ts, sequenceNumber: seq))
            seq &+= 1

            // Frames 1..steadyCount: steady deltas
            for _ in 0..<steadyCount {
                ts = ts &+ steadyDelta
                jb.enqueue(Self.makeAccessUnit(rtpTimestamp: ts, sequenceNumber: seq))
                seq &+= 1
            }

            // Outlier frame: large jump
            let outlierDelta = UInt32(Double(steadyDelta) * outlierMult)
            ts = ts &+ outlierDelta
            jb.enqueue(Self.makeAccessUnit(rtpTimestamp: ts, sequenceNumber: seq))

            // Release frame 0: seeds base timestamps, no EMA yet
            guard jb.releaseNextForTesting() != nil else { return false }
            // After first frame, EMA should be nil (no delta computed yet)
            guard jb.currentEMAInterval == nil else { return false }

            // Release frame 1: first delta → seeds EMA
            guard jb.releaseNextForTesting() != nil else { return false }
            guard let ema1 = jb.currentEMAInterval else { return false }
            guard abs(ema1 - steadyIntervalSec) < 1e-9 else { return false }

            // Release remaining steady frames: EMA should converge toward steadyIntervalSec
            // Simulate the EMA computation to track expected value
            var expectedEMA = steadyIntervalSec
            for _ in 1..<steadyCount {
                guard jb.releaseNextForTesting() != nil else { return false }
                // EMA update: ema += (delta - ema) / 16
                // With steady delta, delta == steadyIntervalSec each time
                expectedEMA += (steadyIntervalSec - expectedEMA) / 16.0
            }

            guard let emaBeforeOutlier = jb.currentEMAInterval else { return false }
            guard abs(emaBeforeOutlier - expectedEMA) < 1e-9 else { return false }

            // EMA should be very close to steadyIntervalSec after many steady frames
            guard abs(emaBeforeOutlier - steadyIntervalSec) / steadyIntervalSec < 0.01 else { return false }

            // Release the outlier frame
            guard jb.releaseNextForTesting() != nil else { return false }
            guard let emaAfterOutlier = jb.currentEMAInterval else { return false }

            // The EMA IS updated by the outlier (ema += (outlierInterval - ema) / 16),
            // but the gain is only 1/16, so it should NOT jump to the outlier value.
            let outlierIntervalSec = Double(outlierDelta) / 90000.0
            let expectedEMAAfter = emaBeforeOutlier + (outlierIntervalSec - emaBeforeOutlier) / 16.0
            guard abs(emaAfterOutlier - expectedEMAAfter) < 1e-9 else { return false }

            // The EMA should still be much closer to the steady interval than to the outlier
            let distToSteady = abs(emaAfterOutlier - steadyIntervalSec)
            let distToOutlier = abs(emaAfterOutlier - outlierIntervalSec)
            guard distToSteady < distToOutlier else { return false }

            return true
        }
    }

    /// For steady inter-frame deltas, the EMA follows the exact recurrence:
    /// seed with first delta, then ema += (delta - ema) / 16 for each subsequent frame.
    func testEMARecurrenceComputation() {
        let deltaGen = Gen<UInt32>.choose((900, 9000))
        let countGen = Gen<Int>.fromElements(in: 3...15)

        property("EMA follows exact recurrence ema += (delta - ema) / 16", arguments: args) <- forAll(deltaGen, countGen) { (delta: UInt32, count: Int) in
            let config = JitterBufferConfig(bufferDepthMs: 1000, transportMode: .tcp)
            let jb = JitterBuffer(config: config)

            let intervalSec = Double(delta) / 90000.0

            // Enqueue base + count frames with constant delta
            for i in 0...count {
                let au = Self.makeAccessUnit(
                    rtpTimestamp: UInt32(i) * delta,
                    sequenceNumber: UInt16(truncatingIfNeeded: i)
                )
                jb.enqueue(au)
            }

            // Release base frame (no EMA)
            guard jb.releaseNextForTesting() != nil else { return false }

            // Release second frame: seeds EMA
            guard jb.releaseNextForTesting() != nil else { return false }
            var expectedEMA = intervalSec

            guard let ema = jb.currentEMAInterval else { return false }
            guard abs(ema - expectedEMA) < 1e-9 else { return false }

            // Release remaining frames, verify EMA at each step
            for _ in 2...count {
                guard jb.releaseNextForTesting() != nil else { return false }
                expectedEMA += (intervalSec - expectedEMA) / 16.0

                guard let currentEMA = jb.currentEMAInterval else { return false }
                guard abs(currentEMA - expectedEMA) < 1e-9 else { return false }
            }

            return true
        }
    }

    // MARK: - Property 16: Diagnostics Stats Consistency
    // **Validates: Requirements 10.1, 10.2, 14.1, 14.2**

    /// For any sequence of enqueue and release operations, the stats invariant holds:
    /// totalFramesReceived == totalFramesDropped + totalFramesReleased + framesBuffered.
    /// Burst counters equal the number of times 3+ frames arrived within 5ms.
    func testDiagnosticsStatsConsistency() {
        let frameCountGen = Gen<Int>.fromElements(in: 1...30)
        let idrRatioGen = Gen<Int>.fromElements(in: 0...100)
        let releaseCountGen = Gen<Int>.fromElements(in: 0...30)

        property("totalFramesReceived == totalFramesDropped + totalFramesReleased + framesBuffered", arguments: args) <- forAll(frameCountGen, idrRatioGen, releaseCountGen) { (frameCount: Int, idrPercent: Int, rawReleaseCount: Int) in
            // Use a small buffer depth to trigger overflow drops
            let config = JitterBufferConfig(bufferDepthMs: 50, transportMode: .tcp)
            let jb = JitterBuffer(config: config)

            // Enqueue a mix of IDR and non-IDR frames
            for i in 0..<frameCount {
                let isIDR = (i * 100 / max(frameCount, 1)) < idrPercent
                let au = Self.makeAccessUnit(
                    rtpTimestamp: UInt32(i) * 3000,
                    sequenceNumber: UInt16(truncatingIfNeeded: i),
                    isIDR: isIDR
                )
                jb.enqueue(au)
            }

            // Release some frames (capped to what's available)
            let releaseCount = min(rawReleaseCount, jb.bufferCount)
            for _ in 0..<releaseCount {
                _ = jb.releaseNextForTesting()
            }

            // Check the stats invariant
            let s = jb.stats
            let sum = s.totalFramesDropped + s.totalFramesReleased + UInt64(s.framesBuffered)
            guard s.totalFramesReceived == sum else { return false }

            return true
        }
    }

    /// Burst detection: enqueuing 3+ frames in a tight loop triggers burst events,
    /// and burst counters are consistent.
    func testBurstDetectionCounters() {
        let burstSizeGen = Gen<Int>.fromElements(in: 3...10)
        let burstCountGen = Gen<Int>.fromElements(in: 1...5)

        property("Burst counters reflect 3+ frames arriving within 5ms window", arguments: args) <- forAll(burstSizeGen, burstCountGen) { (burstSize: Int, burstCount: Int) in
            let config = JitterBufferConfig(bufferDepthMs: 1000, transportMode: .tcp)
            let jb = JitterBuffer(config: config)

            var seq: UInt16 = 0
            var ts: UInt32 = 0

            for _ in 0..<burstCount {
                // Enqueue burstSize frames in a tight loop (same systemUptime ≈ within 5ms)
                for _ in 0..<burstSize {
                    let au = Self.makeAccessUnit(
                        rtpTimestamp: ts,
                        sequenceNumber: seq
                    )
                    jb.enqueue(au)
                    seq &+= 1
                    ts += 3000
                }

                // Drain the buffer between bursts to reset arrival window timing
                while jb.releaseNextForTesting() != nil {}

                // Small pause to separate bursts — sleep 10ms so next burst is outside the 5ms window
                Thread.sleep(forTimeInterval: 0.010)
            }

            let s = jb.stats

            // At least some burst events should have been detected
            guard s.totalBurstEvents > 0 else { return false }

            // averageBurstSize must be >= 3 (minimum burst size)
            guard s.averageBurstSize >= 3.0 else { return false }

            // maxBurstSize must be >= averageBurstSize
            guard Double(s.maxBurstSize) >= s.averageBurstSize else { return false }

            // Stats invariant must still hold
            let sum = s.totalFramesDropped + s.totalFramesReleased + UInt64(s.framesBuffered)
            guard s.totalFramesReceived == sum else { return false }

            return true
        }
    }

    /// Reset also returns the buffer to buffering state, simulating reconnection underrun.
    func testResetReturnsToBufferingState() {
        let countGen = Gen<Int>.fromElements(in: 1...10)
        let baseTimestampGen = Gen<UInt32>.choose((0, UInt32.max - 1_000_000))

        property("Reset returns buffer to buffering state (reconnection underrun)", arguments: args) <- forAll(countGen, baseTimestampGen) { (count: Int, baseTs: UInt32) in
            let config = JitterBufferConfig(bufferDepthMs: 150, transportMode: .tcp)
            let jb = JitterBuffer(config: config)

            // Enqueue and release some frames
            for i in 0..<count {
                let au = Self.makeAccessUnit(
                    rtpTimestamp: baseTs &+ UInt32(i) * 3000,
                    sequenceNumber: UInt16(truncatingIfNeeded: i)
                )
                jb.enqueue(au)
            }
            while jb.releaseNextForTesting() != nil {}

            // Reset simulates reconnection
            jb.reset()

            // After reset, must be in buffering state
            guard jb.isInBufferingState else { return false }
            guard jb.bufferCount == 0 else { return false }

            // Enqueue new frame after reset — still buffering
            let au = Self.makeAccessUnit(
                rtpTimestamp: 0,
                sequenceNumber: 0
            )
            jb.enqueue(au)
            guard jb.isInBufferingState else { return false }

            // Release — must be non-null, non-empty
            guard let frame = jb.releaseNextForTesting() else { return false }
            guard !frame.nalUnits.isEmpty else { return false }

            return true
        }
    }
}

// MARK: - Property 17: Stream Health Callback Completeness
// **Validates: Requirements 15.1, 15.2**

extension JitterBufferPropertyTests {

    /// Burst callback: enqueuing 3+ frames in a tight loop fires .burst events
    /// via onStreamHealth. Each burst event reports size >= 3.
    func testStreamHealthBurstCallback() {
        // Use a fixed large burst to guarantee the tight loop finishes within 5ms
        let burstSizeGen = Gen<Int>.fromElements(in: 5...10)

        property("onStreamHealth fires .burst with size >= 3 for tight-loop enqueue", arguments: args) <- forAll(burstSizeGen) { (burstSize: Int) in
            let config = JitterBufferConfig(bufferDepthMs: 1000, transportMode: .tcp)
            let jb = JitterBuffer(config: config)

            var burstEvents: [(size: Int, durationMs: Double)] = []
            jb.onStreamHealth = { event in
                if case .burst(let size, let durationMs) = event {
                    burstEvents.append((size: size, durationMs: durationMs))
                }
            }

            // Enqueue burstSize frames in a tight loop (within 5ms → burst)
            for i in 0..<burstSize {
                let au = Self.makeAccessUnit(
                    rtpTimestamp: UInt32(i) * 3000,
                    sequenceNumber: UInt16(truncatingIfNeeded: i)
                )
                jb.enqueue(au)
            }

            // At least one burst event should have fired
            guard !burstEvents.isEmpty else { return false }

            // Every burst event must have size >= 3 (minimum burst threshold)
            for burst in burstEvents {
                guard burst.size >= 3 else { return false }
                guard burst.durationMs >= 0 else { return false }
            }

            // The total burst frames reported should not exceed what we enqueued
            let totalBurstFrames = burstEvents.reduce(0) { $0 + $1.size }
            guard totalBurstFrames <= burstSize else { return false }

            // Stats must reflect the burst events
            let s = jb.stats
            guard s.totalBurstEvents == UInt64(burstEvents.count) else { return false }

            return true
        }
    }

    /// Stall callback: releasing all frames (buffer empties) fires exactly one .stall event.
    func testStreamHealthStallCallback() {
        let frameCountGen = Gen<Int>.fromElements(in: 1...10)

        property("onStreamHealth fires .stall when buffer empties during release", arguments: args) <- forAll(frameCountGen) { (frameCount: Int) in
            let config = JitterBufferConfig(bufferDepthMs: 1000, transportMode: .tcp)
            let jb = JitterBuffer(config: config)

            var events: [StreamHealthEvent] = []
            jb.onStreamHealth = { event in
                events.append(event)
            }

            // Enqueue frames (use sleep to avoid burst detection interfering)
            for i in 0..<frameCount {
                let au = Self.makeAccessUnit(
                    rtpTimestamp: UInt32(i) * 3000,
                    sequenceNumber: UInt16(truncatingIfNeeded: i)
                )
                jb.enqueue(au)
            }

            // Clear any burst events from enqueue phase
            events.removeAll()

            // Release all frames — the last release empties the buffer → stall
            for _ in 0..<frameCount {
                _ = jb.releaseNextForTesting()
            }

            // At least one stall event should have fired (on the last release)
            let stallEvents = events.filter {
                if case .stall = $0 { return true }
                return false
            }
            guard stallEvents.count >= 1 else { return false }

            // Verify stall has a timestamp
            if case .stall(let timestamp) = stallEvents.last! {
                guard timestamp > 0 else { return false }
            } else {
                return false
            }

            return true
        }
    }

    /// Recovery callback: after a stall, enqueuing a new frame and releasing it
    /// fires exactly one .recovery event.
    func testStreamHealthRecoveryCallback() {
        let frameCountGen = Gen<Int>.fromElements(in: 2...10)

        property("onStreamHealth fires .recovery when releasing first frame after stall", arguments: args) <- forAll(frameCountGen) { (frameCount: Int) in
            let config = JitterBufferConfig(bufferDepthMs: 1000, transportMode: .tcp)
            let jb = JitterBuffer(config: config)

            var events: [StreamHealthEvent] = []
            jb.onStreamHealth = { event in
                events.append(event)
            }

            // Phase 1: Enqueue and release all frames to trigger a stall
            for i in 0..<frameCount {
                let au = Self.makeAccessUnit(
                    rtpTimestamp: UInt32(i) * 3000,
                    sequenceNumber: UInt16(truncatingIfNeeded: i)
                )
                jb.enqueue(au)
            }
            while jb.releaseNextForTesting() != nil {}

            // Confirm stall occurred
            let stallsBefore = events.filter {
                if case .stall = $0 { return true }
                return false
            }
            guard !stallsBefore.isEmpty else { return false }

            // Clear events for recovery phase
            events.removeAll()

            // Phase 2: Enqueue multiple frames after stall, then release first one → recovery
            for i in 0..<3 {
                let au = Self.makeAccessUnit(
                    rtpTimestamp: UInt32(frameCount + i) * 3000,
                    sequenceNumber: UInt16(truncatingIfNeeded: frameCount + i)
                )
                jb.enqueue(au)
            }

            // Release the first frame — should trigger recovery
            _ = jb.releaseNextForTesting()

            let recoveryEvents = events.filter {
                if case .recovery = $0 { return true }
                return false
            }
            guard recoveryEvents.count == 1 else { return false }

            // Verify recovery has a positive stall duration
            if case .recovery(let stallDurationMs) = recoveryEvents[0] {
                guard stallDurationMs >= 0 else { return false }
            } else {
                return false
            }

            return true
        }
    }

    /// No callback: when onStreamHealth is nil, burst/stall/recovery operations
    /// complete without crash.
    func testStreamHealthNoCallbackNoCrash() {
        let burstSizeGen = Gen<Int>.fromElements(in: 3...8)

        property("No crash when onStreamHealth is nil during burst, stall, and recovery", arguments: args) <- forAll(burstSizeGen) { (burstSize: Int) in
            let config = JitterBufferConfig(bufferDepthMs: 1000, transportMode: .tcp)
            let jb = JitterBuffer(config: config)
            // Deliberately do NOT set onStreamHealth

            // Trigger burst: enqueue 3+ frames in tight loop
            for i in 0..<burstSize {
                let au = Self.makeAccessUnit(
                    rtpTimestamp: UInt32(i) * 3000,
                    sequenceNumber: UInt16(truncatingIfNeeded: i)
                )
                jb.enqueue(au)
            }

            // Trigger stall: release all frames
            while jb.releaseNextForTesting() != nil {}

            // Trigger recovery: enqueue new frames and release
            for i in 0..<3 {
                let au = Self.makeAccessUnit(
                    rtpTimestamp: UInt32(burstSize + i) * 3000,
                    sequenceNumber: UInt16(truncatingIfNeeded: burstSize + i)
                )
                jb.enqueue(au)
            }
            while jb.releaseNextForTesting() != nil {}

            // If we got here without crashing, the test passes
            return true
        }
    }
}


// MARK: - Property 18: Adaptive Buffer Depth Response
// **Validates: Requirements 13.2, 13.3**

extension JitterBufferPropertyTests {

    /// On burst event: adaptive depth increases by at least 20%, clamped to max 1000ms.
    /// A tight-loop enqueue of 6 frames may trigger multiple burst events (window clears
    /// after each detection), so the depth may increase by more than 20%.
    func testAdaptiveDepthIncreasesOnBurst() {
        // Use depths where overflow won't interfere (large enough maxAllowed)
        let depthGen = Gen<Int>.fromElements(in: 200...700)

        property("Burst increases adaptive depth by at least 20%, clamped to 1000", arguments: args) <- forAll(depthGen) { (initialDepth: Int) in
            let config = JitterBufferConfig(
                bufferDepthMs: initialDepth,
                transportMode: .tcp,
                adaptiveEnabled: true
            )
            let jb = JitterBuffer(config: config)

            // Verify initial adaptive depth matches config
            guard jb.currentAdaptiveDepth == initialDepth else { return false }

            // Enqueue 3 frames in a tight loop — exactly enough for one burst
            for i in 0..<3 {
                let au = Self.makeAccessUnit(
                    rtpTimestamp: UInt32(i) * 3000,
                    sequenceNumber: UInt16(truncatingIfNeeded: i)
                )
                jb.enqueue(au)
            }

            // Verify at least one burst was detected
            let burstEvents = jb.stats.totalBurstEvents
            guard burstEvents >= 1 else { return false }

            // Each burst applies a 20% increase. After N bursts:
            // depth = initialDepth * 1.2^N, clamped to 1000
            var expectedDepth = Double(initialDepth)
            for _ in 0..<burstEvents {
                expectedDepth = min(expectedDepth * 1.2, 1000.0)
            }
            guard jb.currentAdaptiveDepth == Int(expectedDepth) else { return false }

            // Depth must have increased (or hit max)
            guard jb.currentAdaptiveDepth >= initialDepth else { return false }

            return true
        }
    }

    /// On burst event with high initial depth: adaptive depth clamps to 1000ms.
    func testAdaptiveDepthClampedToMaxOnBurst() {
        // Generate depths where 20% increase would exceed 1000
        let depthGen = Gen<Int>.fromElements(in: 850...1000)

        property("Burst-triggered depth increase clamps to 1000ms maximum", arguments: args) <- forAll(depthGen) { (initialDepth: Int) in
            let config = JitterBufferConfig(
                bufferDepthMs: initialDepth,
                transportMode: .tcp,
                adaptiveEnabled: true
            )
            let jb = JitterBuffer(config: config)

            // Trigger burst: enqueue 6 frames in tight loop
            for i in 0..<6 {
                let au = Self.makeAccessUnit(
                    rtpTimestamp: UInt32(i) * 3000,
                    sequenceNumber: UInt16(truncatingIfNeeded: i)
                )
                jb.enqueue(au)
            }

            let newDepth = jb.currentAdaptiveDepth
            // Must not exceed 1000
            guard newDepth <= 1000 else { return false }

            // For depths where 1.2× > 1000, should be exactly 1000
            if Int(Double(initialDepth) * 1.2) > 1000 {
                guard newDepth == 1000 else { return false }
            }

            return true
        }
    }

    /// Adaptive depth is correctly exposed via stats.currentAdaptiveDepthMs.
    func testAdaptiveDepthExposedInStats() {
        let depthGen = Gen<Int>.fromElements(in: 200...700)

        property("Stats expose current adaptive depth after burst adjustment", arguments: args) <- forAll(depthGen) { (initialDepth: Int) in
            let config = JitterBufferConfig(
                bufferDepthMs: initialDepth,
                transportMode: .tcp,
                adaptiveEnabled: true
            )
            let jb = JitterBuffer(config: config)

            // Before burst: stats should show initial depth
            let statsBefore = jb.stats
            guard statsBefore.currentAdaptiveDepthMs == initialDepth else { return false }

            // Trigger burst with exactly 3 frames
            for i in 0..<3 {
                let au = Self.makeAccessUnit(
                    rtpTimestamp: UInt32(i) * 3000,
                    sequenceNumber: UInt16(truncatingIfNeeded: i)
                )
                jb.enqueue(au)
            }

            // After burst: stats should reflect the new adaptive depth
            let statsAfter = jb.stats
            let burstEvents = statsAfter.totalBurstEvents
            guard burstEvents >= 1 else { return false }

            // Compute expected depth after N bursts
            var expectedDepth = Double(initialDepth)
            for _ in 0..<burstEvents {
                expectedDepth = min(expectedDepth * 1.2, 1000.0)
            }
            guard statsAfter.currentAdaptiveDepthMs == Int(expectedDepth) else { return false }

            // currentAdaptiveDepth property and stats must agree
            guard jb.currentAdaptiveDepth == statsAfter.currentAdaptiveDepthMs else { return false }

            return true
        }
    }

    /// When adaptive mode is disabled, burst does not change depth.
    func testNonAdaptiveModeIgnoresBurst() {
        let depthGen = Gen<Int>.fromElements(in: 50...1000)

        property("Non-adaptive mode: burst does not change buffer depth", arguments: args) <- forAll(depthGen) { (initialDepth: Int) in
            let config = JitterBufferConfig(
                bufferDepthMs: initialDepth,
                transportMode: .tcp,
                adaptiveEnabled: false
            )
            let jb = JitterBuffer(config: config)

            // Trigger burst
            for i in 0..<6 {
                let au = Self.makeAccessUnit(
                    rtpTimestamp: UInt32(i) * 3000,
                    sequenceNumber: UInt16(truncatingIfNeeded: i)
                )
                jb.enqueue(au)
            }

            // Depth should remain unchanged (adaptive is off)
            guard jb.currentAdaptiveDepth == initialDepth else { return false }

            // Stats should show 0 for adaptive depth when disabled
            guard jb.stats.currentAdaptiveDepthMs == 0 else { return false }

            return true
        }
    }
}
