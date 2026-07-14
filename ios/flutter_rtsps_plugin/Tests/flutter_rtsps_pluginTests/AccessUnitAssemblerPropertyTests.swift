import XCTest
import SwiftCheck
@testable import flutter_rtsps_plugin

// Feature: rtsps-jitter-buffer, Property 12: Access Unit Assembly Round-Trip

/// **Validates: Requirements 6.1, 6.2**
///
/// Property 12: Access Unit Assembly Round-Trip
/// For any sequence of NAL units where the last has marker bit = true,
/// the emitted AccessUnit contains exactly those NALs (excluding SPS/PPS)
/// in order, with RTP timestamp and sequence number matching the final NAL.
final class AccessUnitAssemblerPropertyTests: XCTestCase {

    private let args = CheckerArguments(maxAllowableSuccessfulTests: 30)

    // MARK: - Generators

    /// Generate a random NAL type that is NOT SPS (7) or PPS (8).
    /// Valid H.264 NAL types are 0–31; we exclude 7 and 8.
    private static let nonParameterSetNalTypeGen: Gen<UInt8> =
        Gen<UInt8>.fromElements(in: 1...6)
            .proliferate(withSize: 1)
            .flatMap { _ in
                Gen<UInt8>.one(of: [
                    Gen<UInt8>.fromElements(in: 1...6),
                    Gen<UInt8>.fromElements(in: 9...23),
                ])
            }

    /// Generate a random NAL Data with a specific NAL type in the header byte.
    /// The first byte encodes forbidden_zero_bit (0) | NRI (random 2 bits) | type (5 bits).
    private static func nalDataGen(nalType: UInt8, minPayloadSize: Int = 1, maxPayloadSize: Int = 64) -> Gen<Data> {
        let payloadSizeGen = Gen<Int>.fromElements(in: minPayloadSize...maxPayloadSize)
        let nriGen = Gen<UInt8>.fromElements(in: 0...3)

        return Gen<(Int, UInt8)>.zip(payloadSizeGen, nriGen).map { (size, nri) in
            var bytes = [UInt8](repeating: 0, count: size + 1)
            // NAL header: forbidden_zero_bit=0, nal_ref_idc=nri, nal_unit_type=nalType
            bytes[0] = (nri << 5) | (nalType & 0x1F)
            // Fill payload with deterministic but varied data
            for i in 1..<bytes.count {
                bytes[i] = UInt8(truncatingIfNeeded: i &* 37 &+ Int(nalType))
            }
            return Data(bytes)
        }
    }

    /// Generate a single RtpNalUnit with a non-SPS/PPS type.
    private static func nonParamNalUnitGen(
        rtpTimestamp: UInt32,
        sequenceNumber: UInt16,
        isFrameComplete: Bool
    ) -> Gen<RtpNalUnit> {
        return nonParameterSetNalTypeGen.flatMap { nalType in
            nalDataGen(nalType: nalType).map { data in
                RtpNalUnit(
                    data: data,
                    isFrameComplete: isFrameComplete,
                    rtpTimestamp: rtpTimestamp,
                    sequenceNumber: sequenceNumber
                )
            }
        }
    }

    // MARK: - Property 12: Access Unit Assembly Round-Trip

    /// For any sequence of non-SPS/PPS NAL units where the last has
    /// marker bit = true, the emitted AccessUnit contains exactly those
    /// NALs in order, with RTP timestamp and sequence number matching
    /// the final NAL.
    func testAccessUnitAssemblyRoundTrip() {
        let countGen = Gen<UInt>.fromElements(in: 1...20)
        let timestampGen = Gen<UInt32>.choose((0, UInt32.max))
        let seqGen = Gen<UInt16>.choose((0, UInt16.max))

        property("Access unit assembly round-trip preserves NALs, timestamp, and sequence number", arguments: args) <- forAll(countGen, timestampGen, seqGen) { (count: UInt, finalTimestamp: UInt32, finalSeq: UInt16) in
            let nalCount = Int(count)
            let assembler = AccessUnitAssembler()
            var emittedAccessUnits: [AccessUnit] = []
            assembler.onAccessUnit = { au in
                emittedAccessUnits.append(au)
            }

            // Generate NAL units deterministically from the inputs
            var expectedNalDatas: [Data] = []

            for i in 0..<nalCount {
                let isLast = (i == nalCount - 1)
                // Use a non-parameter-set NAL type (cycle through 1,2,3,4,5,6,9,10...)
                let availableTypes: [UInt8] = [1, 2, 3, 4, 5, 6, 9, 10, 11, 12]
                let nalType = availableTypes[i % availableTypes.count]
                let headerByte = (UInt8(2) << 5) | (nalType & 0x1F) // NRI=2
                var nalBytes = [UInt8](repeating: 0, count: 4)
                nalBytes[0] = headerByte
                nalBytes[1] = UInt8(truncatingIfNeeded: i)
                nalBytes[2] = UInt8(truncatingIfNeeded: nalCount)
                nalBytes[3] = UInt8(truncatingIfNeeded: finalTimestamp)
                let nalData = Data(nalBytes)

                expectedNalDatas.append(nalData)

                let unit = RtpNalUnit(
                    data: nalData,
                    isFrameComplete: isLast,
                    rtpTimestamp: finalTimestamp,
                    sequenceNumber: finalSeq
                )
                assembler.feedNalUnit(unit)
            }

            // Exactly one access unit should be emitted
            guard emittedAccessUnits.count == 1 else { return false }
            let au = emittedAccessUnits[0]

            // NAL count must match
            guard au.nalUnits.count == expectedNalDatas.count else { return false }

            // NALs must be in order and identical
            for (idx, nalData) in expectedNalDatas.enumerated() {
                guard au.nalUnits[idx] == nalData else { return false }
            }

            // Timestamp and sequence number must match the final NAL
            return au.rtpTimestamp == finalTimestamp
                && au.sequenceNumber == finalSeq
        }
    }

    /// SPS (type 7) and PPS (type 8) NAL units are excluded from the
    /// emitted AccessUnit but non-parameter-set NALs are preserved.
    func testSPSPPSExcludedFromAccessUnit() {
        let timestampGen = Gen<UInt32>.choose((0, UInt32.max))
        let seqGen = Gen<UInt16>.choose((0, UInt16.max))
        let nonParamCountGen = Gen<UInt>.fromElements(in: 1...10)
        let spsCountGen = Gen<UInt>.fromElements(in: 0...3)
        let ppsCountGen = Gen<UInt>.fromElements(in: 0...3)

        property("SPS/PPS NALs are excluded from emitted access unit", arguments: args) <- forAll(timestampGen, seqGen, nonParamCountGen, spsCountGen, ppsCountGen) { (ts: UInt32, seq: UInt16, nonParamCount: UInt, spsCount: UInt, ppsCount: UInt) in
            let assembler = AccessUnitAssembler()
            var emittedAccessUnits: [AccessUnit] = []
            var parameterSets: [(Data, UInt8)] = []
            assembler.onAccessUnit = { au in emittedAccessUnits.append(au) }
            assembler.onParameterSet = { data, nalType in parameterSets.append((data, nalType)) }

            var expectedNonParamNals: [Data] = []
            let totalNonParam = Int(nonParamCount)
            let totalSps = Int(spsCount)
            let totalPps = Int(ppsCount)

            // Feed SPS NALs (type 7)
            for i in 0..<totalSps {
                let headerByte: UInt8 = (3 << 5) | 7
                let data = Data([headerByte, UInt8(truncatingIfNeeded: i)])
                let unit = RtpNalUnit(data: data, isFrameComplete: false, rtpTimestamp: ts, sequenceNumber: seq)
                assembler.feedNalUnit(unit)
            }

            // Feed PPS NALs (type 8)
            for i in 0..<totalPps {
                let headerByte: UInt8 = (3 << 5) | 8
                let data = Data([headerByte, UInt8(truncatingIfNeeded: i)])
                let unit = RtpNalUnit(data: data, isFrameComplete: false, rtpTimestamp: ts, sequenceNumber: seq)
                assembler.feedNalUnit(unit)
            }

            // Feed non-parameter-set NALs
            for i in 0..<totalNonParam {
                let isLast = (i == totalNonParam - 1)
                let nalType: UInt8 = [1, 2, 5, 6, 9][i % 5]
                let headerByte = (UInt8(2) << 5) | nalType
                let data = Data([headerByte, UInt8(truncatingIfNeeded: i), UInt8(truncatingIfNeeded: ts)])
                expectedNonParamNals.append(data)
                let unit = RtpNalUnit(data: data, isFrameComplete: isLast, rtpTimestamp: ts, sequenceNumber: seq)
                assembler.feedNalUnit(unit)
            }

            // Exactly one access unit emitted
            guard emittedAccessUnits.count == 1 else { return false }
            let au = emittedAccessUnits[0]

            // Access unit contains only non-parameter-set NALs
            guard au.nalUnits.count == expectedNonParamNals.count else { return false }
            for (idx, expected) in expectedNonParamNals.enumerated() {
                guard au.nalUnits[idx] == expected else { return false }
            }

            // Parameter sets were forwarded via callback
            let expectedParamCount = totalSps + totalPps
            guard parameterSets.count == expectedParamCount else { return false }

            return au.rtpTimestamp == ts && au.sequenceNumber == seq
        }
    }

    /// Mixed sequence: interleaved SPS/PPS and slice NALs still produce
    /// correct access unit with only non-parameter-set NALs in order.
    func testInterleavedParameterSetsPreserveOrder() {
        let timestampGen = Gen<UInt32>.choose((0, UInt32.max))
        let seqGen = Gen<UInt16>.choose((0, UInt16.max))

        property("Interleaved SPS/PPS and slice NALs preserve non-param NAL order", arguments: args) <- forAll(timestampGen, seqGen) { (ts: UInt32, seq: UInt16) in
            let assembler = AccessUnitAssembler()
            var emittedAccessUnits: [AccessUnit] = []
            assembler.onAccessUnit = { au in emittedAccessUnits.append(au) }

            // Sequence: SPS, slice1, PPS, slice2, slice3 (marker=true)
            let spsData = Data([(3 << 5) | 7, 0xAA])
            let slice1Data = Data([(2 << 5) | 1, 0x01])
            let ppsData = Data([(3 << 5) | 8, 0xBB])
            let slice2Data = Data([(2 << 5) | 5, 0x02]) // IDR
            let slice3Data = Data([(2 << 5) | 1, 0x03])

            var expectedNals: [Data] = []

            assembler.feedNalUnit(RtpNalUnit(data: spsData, isFrameComplete: false, rtpTimestamp: ts, sequenceNumber: seq))
            // SPS excluded

            assembler.feedNalUnit(RtpNalUnit(data: slice1Data, isFrameComplete: false, rtpTimestamp: ts, sequenceNumber: seq))
            expectedNals.append(slice1Data)

            assembler.feedNalUnit(RtpNalUnit(data: ppsData, isFrameComplete: false, rtpTimestamp: ts, sequenceNumber: seq))
            // PPS excluded

            assembler.feedNalUnit(RtpNalUnit(data: slice2Data, isFrameComplete: false, rtpTimestamp: ts, sequenceNumber: seq))
            expectedNals.append(slice2Data)

            assembler.feedNalUnit(RtpNalUnit(data: slice3Data, isFrameComplete: true, rtpTimestamp: ts, sequenceNumber: seq))
            expectedNals.append(slice3Data)

            guard emittedAccessUnits.count == 1 else { return false }
            let au = emittedAccessUnits[0]

            guard au.nalUnits.count == expectedNals.count else { return false }
            for (idx, expected) in expectedNals.enumerated() {
                guard au.nalUnits[idx] == expected else { return false }
            }

            return au.rtpTimestamp == ts
                && au.sequenceNumber == seq
                && au.isIDR == true // slice2 is type 5
        }
    }

    // MARK: - Timestamp-Change Frame Boundary Fallback

    /// A new RTP timestamp closes the previous access unit even when the
    /// previous frame's marker bit was never set. This guards against
    /// encoders that drop/misplace the marker bit (observed on the H2C under
    /// load), which would otherwise merge two frames into one malformed unit.
    func testTimestampChangeClosesPreviousFrameWithoutMarker() {
        let assembler = AccessUnitAssembler()
        var emitted: [AccessUnit] = []
        assembler.onAccessUnit = { emitted.append($0) }

        // Frame 1: a single slice at T=1000, NO marker bit.
        let slice1 = Data([(2 << 5) | 1, 0x11])
        assembler.feedNalUnit(RtpNalUnit(data: slice1, isFrameComplete: false,
                                         rtpTimestamp: 1000, sequenceNumber: 10))

        // Nothing emitted yet — no marker, no timestamp change.
        XCTAssertEqual(emitted.count, 0)

        // Frame 2: a slice at T=4000 (new timestamp), also NO marker bit.
        // Arrival of the new timestamp must flush frame 1.
        let slice2 = Data([(2 << 5) | 1, 0x22])
        assembler.feedNalUnit(RtpNalUnit(data: slice2, isFrameComplete: false,
                                         rtpTimestamp: 4000, sequenceNumber: 11))

        XCTAssertEqual(emitted.count, 1, "New RTP timestamp should close the previous frame")
        XCTAssertEqual(emitted[0].rtpTimestamp, 1000, "Emitted AU carries the previous frame's timestamp")
        XCTAssertEqual(emitted[0].sequenceNumber, 10, "Emitted AU carries the previous frame's last seq")
        XCTAssertEqual(emitted[0].nalUnits, [slice1])

        // Frame 2 finally gets its marker bit at T=4000.
        let slice2End = Data([(2 << 5) | 1, 0x23])
        assembler.feedNalUnit(RtpNalUnit(data: slice2End, isFrameComplete: true,
                                         rtpTimestamp: 4000, sequenceNumber: 12))

        XCTAssertEqual(emitted.count, 2)
        XCTAssertEqual(emitted[1].rtpTimestamp, 4000)
        XCTAssertEqual(emitted[1].sequenceNumber, 12)
        XCTAssertEqual(emitted[1].nalUnits, [slice2, slice2End],
                       "Frame 2 accumulates both of its NALs")
    }

    /// Regression: a normal single-timestamp frame terminated by a marker bit
    /// still emits exactly one access unit (the timestamp-change fallback must
    /// not fire spuriously when marker bits are reliable).
    func testReliableMarkerBitEmitsExactlyOncePerFrame() {
        let assembler = AccessUnitAssembler()
        var emitted: [AccessUnit] = []
        assembler.onAccessUnit = { emitted.append($0) }

        // Two multi-NAL frames, each properly terminated by a marker bit.
        for (ts, seqBase) in [(UInt32(1000), UInt16(10)), (UInt32(4000), UInt16(20))] {
            assembler.feedNalUnit(RtpNalUnit(data: Data([(2 << 5) | 1, 0x01]),
                                             isFrameComplete: false,
                                             rtpTimestamp: ts, sequenceNumber: seqBase))
            assembler.feedNalUnit(RtpNalUnit(data: Data([(2 << 5) | 5, 0x02]),
                                             isFrameComplete: true,
                                             rtpTimestamp: ts, sequenceNumber: seqBase + 1))
        }

        XCTAssertEqual(emitted.count, 2, "Each marker-terminated frame emits exactly once")
        XCTAssertEqual(emitted[0].rtpTimestamp, 1000)
        XCTAssertEqual(emitted[0].nalUnits.count, 2)
        XCTAssertEqual(emitted[1].rtpTimestamp, 4000)
        XCTAssertEqual(emitted[1].nalUnits.count, 2)
    }

    /// A missed marker followed by the next frame's SPS/PPS (parameter sets
    /// carry the new timestamp) still flushes the previous frame correctly.
    func testTimestampChangeViaParameterSetFlushesPreviousFrame() {
        let assembler = AccessUnitAssembler()
        var emitted: [AccessUnit] = []
        var params: [(Data, UInt8)] = []
        assembler.onAccessUnit = { emitted.append($0) }
        assembler.onParameterSet = { params.append(($0, $1)) }

        // Frame 1 slice at T=1000, marker dropped.
        let slice1 = Data([(2 << 5) | 1, 0xAA])
        assembler.feedNalUnit(RtpNalUnit(data: slice1, isFrameComplete: false,
                                         rtpTimestamp: 1000, sequenceNumber: 30))

        // Frame 2 begins with SPS at T=4000 — new timestamp flushes frame 1.
        let sps = Data([(3 << 5) | 7, 0xBB])
        assembler.feedNalUnit(RtpNalUnit(data: sps, isFrameComplete: false,
                                         rtpTimestamp: 4000, sequenceNumber: 31))

        XCTAssertEqual(emitted.count, 1, "SPS with a new timestamp flushes the prior frame")
        XCTAssertEqual(emitted[0].rtpTimestamp, 1000)
        XCTAssertEqual(emitted[0].nalUnits, [slice1])
        XCTAssertEqual(params.count, 1, "SPS is forwarded, not merged into the flushed frame")
    }
}
