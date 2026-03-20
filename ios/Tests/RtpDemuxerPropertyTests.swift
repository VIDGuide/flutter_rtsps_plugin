import XCTest
import SwiftCheck
@testable import flutter_rtsps_plugin

// Feature: rtsps-jitter-buffer
// Properties 9, 10, 11 — RtpDemuxer FU-A and STAP-A property tests

final class RtpDemuxerPropertyTests: XCTestCase {

    private let args = CheckerArguments(maxAllowableSuccessfulTests: 30)

    // MARK: - Helpers

    /// Builds a minimal 12-byte RTP header with a given sequence number and optional marker bit.
    /// Uses a fixed timestamp of 1000 and SSRC of 0xDEADBEEF.
    private func rtpHeader(marker: Bool, seq: UInt16, timestamp: UInt32 = 1000) -> [UInt8] {
        let byte0: UInt8 = 0x80 // V=2, P=0, X=0, CC=0
        let byte1: UInt8 = (marker ? 0x80 : 0x00) | 0x60 // M | PT=96
        let seqHi = UInt8(seq >> 8)
        let seqLo = UInt8(seq & 0xFF)
        let ts: [UInt8] = [
            UInt8((timestamp >> 24) & 0xFF),
            UInt8((timestamp >> 16) & 0xFF),
            UInt8((timestamp >> 8) & 0xFF),
            UInt8(timestamp & 0xFF)
        ]
        let ssrc: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        return [byte0, byte1, seqHi, seqLo] + ts + ssrc
    }

    /// Creates a FU-A RTP packet.
    /// - Parameters:
    ///   - nri: NRI bits (0-3), placed in bits 5-6 of the FU indicator.
    ///   - nalType: The NAL unit type (5 bits) placed in the FU header.
    ///   - isStart: FU-A start bit.
    ///   - isEnd: FU-A end bit.
    ///   - seq: RTP sequence number.
    ///   - marker: RTP marker bit.
    ///   - fragmentPayload: The fragment payload bytes (after FU indicator + FU header).
    private func fuaPacket(nri: UInt8 = 3, nalType: UInt8 = 5, isStart: Bool, isEnd: Bool,
                           seq: UInt16, marker: Bool, fragmentPayload: [UInt8]) -> Data {
        // FU indicator: forbidden=0, NRI, type=28
        let fuIndicator: UInt8 = (nri << 5) | 28
        // FU header: S | E | R=0 | nalType
        var fuHeader: UInt8 = nalType & 0x1F
        if isStart { fuHeader |= 0x80 }
        if isEnd { fuHeader |= 0x40 }
        let rtp = rtpHeader(marker: marker, seq: seq) + [fuIndicator, fuHeader] + fragmentPayload
        return Data(rtp)
    }

    /// Creates a STAP-A RTP packet from an array of NAL units.
    /// - Parameters:
    ///   - nalUnits: Array of raw NAL unit bytes (each without size prefix).
    ///   - seq: RTP sequence number.
    ///   - marker: RTP marker bit.
    private func stapAPacket(nalUnits: [[UInt8]], seq: UInt16, marker: Bool) -> Data {
        // STAP-A header: forbidden=0, NRI=3, type=24
        var payload: [UInt8] = [0x78] // (3 << 5) | 24 = 0x60 | 0x18 = 0x78
        for nal in nalUnits {
            let size = UInt16(nal.count)
            payload.append(UInt8(size >> 8))
            payload.append(UInt8(size & 0xFF))
            payload.append(contentsOf: nal)
        }
        let rtp = rtpHeader(marker: marker, seq: seq) + payload
        return Data(rtp)
    }

    private func makeDummyTransport() -> RtspTransport {
        RtspTransport()
    }

    // MARK: - Property 9: FU-A Sequence Gap Discards Entire Buffer
    // **Validates: Requirements 3.2, 3.3**

    /// Any continuation/end fragment with sequence number not exactly previous + 1
    /// causes entire reassembly buffer discard. No NAL emitted.
    func testFuASequenceGapDiscardsEntireBuffer() {
        // Generate: number of valid continuation fragments (0-5), then a gap size (2-100)
        let validContGen = Gen<UInt8>.choose((0, 5))
        let gapSizeGen = Gen<UInt16>.choose((2, 100))
        let fragSizeGen = Gen<Int>.choose((1, 20))

        property("FU-A sequence gap discards entire buffer, no NAL emitted", arguments: args) <- forAll(validContGen, gapSizeGen, fragSizeGen) { (validConts: UInt8, gapSize: UInt16, fragSize: Int) in
            let demuxer = RtpDemuxer(transport: self.makeDummyTransport())
            var emittedNals: [RtpNalUnit] = []
            demuxer.onNalUnit = { unit in emittedNals.append(unit) }

            let startSeq: UInt16 = 100
            let fragBytes = [UInt8](repeating: 0xAA, count: fragSize)

            // Send start fragment
            demuxer.processRtpPacketForTesting(self.fuaPacket(
                isStart: true, isEnd: false, seq: startSeq, marker: false, fragmentPayload: fragBytes))

            // Send valid continuation fragments
            for i in 0..<UInt16(validConts) {
                demuxer.processRtpPacketForTesting(self.fuaPacket(
                    isStart: false, isEnd: false, seq: startSeq + 1 + i, marker: false, fragmentPayload: fragBytes))
            }

            // No NAL should have been emitted yet
            guard emittedNals.isEmpty else { return false }

            // Send fragment with a gap (skip gapSize sequence numbers)
            let gapSeq = startSeq + 1 + UInt16(validConts) + gapSize
            demuxer.processRtpPacketForTesting(self.fuaPacket(
                isStart: false, isEnd: true, seq: gapSeq, marker: true, fragmentPayload: fragBytes))

            // No NAL should be emitted — the gap discards the buffer
            return emittedNals.isEmpty
        }
    }

    // MARK: - Property 10: FU-A Round-Trip Reassembly
    // **Validates: Requirements 3.1, 3.7**

    /// Valid FU-A sequence (start + continuations + end) with consecutive seq numbers
    /// reassembles to original NAL. Marker bit from end fragment forwarded.
    func testFuARoundTripReassembly() {
        let numContsGen = Gen<UInt8>.choose((0, 8))
        let fragSizeGen = Gen<Int>.choose((1, 50))
        let nalTypeGen = Gen<UInt8>.choose((1, 23))
        let nriGen = Gen<UInt8>.choose((0, 3))
        let markerGen = Gen<Bool>.pure(true)

        property("FU-A round-trip: consecutive fragments reassemble to original NAL", arguments: args) <- forAll(numContsGen, fragSizeGen, nalTypeGen, nriGen, markerGen) { (numConts: UInt8, fragSize: Int, nalType: UInt8, nri: UInt8, marker: Bool) in
            let demuxer = RtpDemuxer(transport: self.makeDummyTransport())
            var emittedNals: [RtpNalUnit] = []
            demuxer.onNalUnit = { unit in emittedNals.append(unit) }

            let startSeq: UInt16 = 200
            let totalFragments = Int(numConts) + 2 // start + continuations + end

            // Generate unique payload per fragment so we can verify concatenation
            var allPayloads: [[UInt8]] = []
            for i in 0..<totalFragments {
                let payload = [UInt8](repeating: UInt8(truncatingIfNeeded: i + 1), count: fragSize)
                allPayloads.append(payload)
            }

            // Send start fragment
            demuxer.processRtpPacketForTesting(self.fuaPacket(
                nri: nri, nalType: nalType, isStart: true, isEnd: false,
                seq: startSeq, marker: false, fragmentPayload: allPayloads[0]))

            // Send continuation fragments
            for i in 0..<Int(numConts) {
                demuxer.processRtpPacketForTesting(self.fuaPacket(
                    nri: nri, nalType: nalType, isStart: false, isEnd: false,
                    seq: startSeq + UInt16(i + 1), marker: false, fragmentPayload: allPayloads[i + 1]))
            }

            // Send end fragment with marker bit
            let endSeq = startSeq + UInt16(numConts) + 1
            demuxer.processRtpPacketForTesting(self.fuaPacket(
                nri: nri, nalType: nalType, isStart: false, isEnd: true,
                seq: endSeq, marker: marker, fragmentPayload: allPayloads[totalFragments - 1]))

            // Should have emitted exactly one NAL
            guard emittedNals.count == 1 else { return false }
            let emitted = emittedNals[0]

            // Verify marker bit forwarded
            guard emitted.isFrameComplete == marker else { return false }

            // Verify reassembled NAL: header byte = (nri << 5) | nalType, then all fragment payloads
            let expectedHeader: UInt8 = (nri << 5) | (nalType & 0x1F)
            var expectedData = Data([expectedHeader])
            for payload in allPayloads {
                expectedData.append(contentsOf: payload)
            }
            return emitted.data == expectedData
        }
    }

    // MARK: - Property 11: STAP-A Extraction and Marker Bit Placement
    // **Validates: Requirements 4.1, 4.3**

    /// All N NAL units extracted from STAP-A. Marker bit forwarded only with last NAL;
    /// preceding NALs have marker = false.
    func testStapAExtractionAndMarkerBitPlacement() {
        let numNalsGen = Gen<Int>.choose((1, 8))
        let nalSizeGen = Gen<Int>.choose((1, 30))

        property("STAP-A: all NALs extracted, marker only on last", arguments: args) <- forAll(numNalsGen, nalSizeGen) { (numNals: Int, nalSize: Int) in
            let demuxer = RtpDemuxer(transport: self.makeDummyTransport())
            var emittedNals: [RtpNalUnit] = []
            demuxer.onNalUnit = { unit in emittedNals.append(unit) }

            // Generate NAL units with distinct content
            var nalUnits: [[UInt8]] = []
            for i in 0..<numNals {
                // NAL type 1 (non-IDR slice) with unique fill byte
                var nal = [UInt8](repeating: UInt8(truncatingIfNeeded: i + 0x10), count: nalSize)
                nal[0] = 0x41 // forbidden=0, NRI=2, type=1
                nalUnits.append(nal)
            }

            // Send STAP-A packet with marker=true
            demuxer.processRtpPacketForTesting(self.stapAPacket(
                nalUnits: nalUnits, seq: 300, marker: true))

            // Should have emitted exactly numNals NAL units
            guard emittedNals.count == numNals else { return false }

            // Verify each NAL's data matches
            for i in 0..<numNals {
                guard emittedNals[i].data == Data(nalUnits[i]) else { return false }
            }

            // Verify marker bit placement: only last NAL has marker=true
            for i in 0..<numNals - 1 {
                guard emittedNals[i].isFrameComplete == false else { return false }
            }
            guard emittedNals[numNals - 1].isFrameComplete == true else { return false }

            return true
        }
    }
}
