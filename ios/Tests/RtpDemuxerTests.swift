import XCTest
@testable import flutter_rtsps_plugin

// RtpDemuxer, RtpStats, RtspTransport, and RtspError are defined in the
// plugin's Classes/ directory. Add them to the test target's compile sources.

final class RtpDemuxerTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a minimal 4-byte TCP interleaved frame header.
    private func interleavedHeader(channel: UInt8, length: UInt16) -> [UInt8] {
        [0x24, channel, UInt8(length >> 8), UInt8(length & 0xFF)]
    }

    /// Builds a minimal 12-byte RTP fixed header.
    ///
    /// - Parameters:
    ///   - marker: Whether the marker bit should be set.
    ///   - seq: 16-bit sequence number.
    ///   - ssrc: 32-bit SSRC.
    private func rtpHeader(marker: Bool, seq: UInt16 = 1, ssrc: UInt32 = 0xDEADBEEF) -> [UInt8] {
        // Byte 0: V=2, P=0, X=0, CC=0  →  0b10000000 = 0x80
        let byte0: UInt8 = 0x80
        // Byte 1: M | PT=96 (0x60)
        let byte1: UInt8 = (marker ? 0x80 : 0x00) | 0x60
        let seqHi = UInt8(seq >> 8)
        let seqLo = UInt8(seq & 0xFF)
        // Timestamp (4 bytes) — arbitrary value
        let ts: [UInt8] = [0x00, 0x00, 0x03, 0xE8]
        let ssrcBytes: [UInt8] = [
            UInt8((ssrc >> 24) & 0xFF),
            UInt8((ssrc >> 16) & 0xFF),
            UInt8((ssrc >>  8) & 0xFF),
            UInt8( ssrc        & 0xFF)
        ]
        return [byte0, byte1, seqHi, seqLo] + ts + ssrcBytes
    }

    // MARK: - Single NAL Unit Packet (Req 2.4, 11.6)

    /// A single-packet RTP payload containing one complete NAL unit is forwarded
    /// directly to the onNalUnit callback with the correct marker bit.
    func testSingleNalUnitPacket() {
        let demuxer = RtpDemuxer(transport: makeDummyTransport())

        // NAL unit: type 5 (IDR slice)
        let nalPayload: [UInt8] = [0x65, 0xAA, 0xBB, 0xCC]
        let rtp = rtpHeader(marker: true) + nalPayload

        var receivedNal: Data?
        var receivedMarker: Bool?
        demuxer.onNalUnit = { unit in
            receivedNal = unit.data
            receivedMarker = unit.isFrameComplete
        }

        demuxer.processRtpPacketForTesting(Data(rtp))

        XCTAssertEqual(receivedNal, Data(nalPayload), "NAL unit payload should match")
        XCTAssertEqual(receivedMarker, true, "Marker bit should be forwarded")
    }

    /// Marker bit = false is forwarded correctly for non-final packets.
    func testSingleNalUnitPacketNoMarker() {
        let demuxer = RtpDemuxer(transport: makeDummyTransport())

        let nalPayload: [UInt8] = [0x41, 0x01, 0x02]
        let rtp = rtpHeader(marker: false) + nalPayload

        var receivedMarker: Bool?
        demuxer.onNalUnit = { unit in receivedMarker = unit.isFrameComplete }

        demuxer.processRtpPacketForTesting(Data(rtp))

        XCTAssertEqual(receivedMarker, false)
    }

    // MARK: - FU-A Fragmented Packet (Req 2.7, 11.6)

    /// Three FU-A fragments are reassembled into a single complete NAL unit.
    func testFuAFragmentedPacket() {
        let demuxer = RtpDemuxer(transport: makeDummyTransport())

        // FU indicator: NRI=3 (0x60), type=28 (0x1C)  →  0x7C
        let fuIndicator: UInt8 = 0x7C
        // NAL type inside FU header: 5 (IDR)
        let nalType: UInt8 = 0x05

        // Fragment 1: S=1, E=0  →  FU header = 0x85
        let frag1Payload: [UInt8] = [0xAA, 0xBB]
        let rtp1 = rtpHeader(marker: false, seq: 1) + [fuIndicator, 0x85] + frag1Payload

        // Fragment 2: S=0, E=0  →  FU header = 0x05
        let frag2Payload: [UInt8] = [0xCC, 0xDD]
        let rtp2 = rtpHeader(marker: false, seq: 2) + [fuIndicator, 0x05] + frag2Payload

        // Fragment 3: S=0, E=1  →  FU header = 0x45
        let frag3Payload: [UInt8] = [0xEE, 0xFF]
        let rtp3 = rtpHeader(marker: true, seq: 3) + [fuIndicator, 0x45] + frag3Payload

        var receivedNal: Data?
        var receivedMarker: Bool?
        demuxer.onNalUnit = { unit in
            receivedNal = unit.data
            receivedMarker = unit.isFrameComplete
        }

        demuxer.processRtpPacketForTesting(Data(rtp1))
        XCTAssertNil(receivedNal, "NAL should not be emitted until FU-A end")

        demuxer.processRtpPacketForTesting(Data(rtp2))
        XCTAssertNil(receivedNal, "NAL should not be emitted until FU-A end")

        demuxer.processRtpPacketForTesting(Data(rtp3))
        XCTAssertNotNil(receivedNal, "NAL should be emitted after FU-A end")

        // Reconstructed NAL header: (fuIndicator & 0xE0) | nalType = 0x60 | 0x05 = 0x65
        let expectedNalHeader: UInt8 = (fuIndicator & 0xE0) | nalType
        let expectedNal = Data([expectedNalHeader] + frag1Payload + frag2Payload + frag3Payload)
        XCTAssertEqual(receivedNal, expectedNal, "Reassembled NAL unit should match")
        XCTAssertEqual(receivedMarker, true, "Marker bit from final fragment should be forwarded")
    }

    /// A FU-A end/middle fragment arriving without a prior start is silently discarded.
    func testFuAFragmentWithoutStartIsDiscarded() {
        let demuxer = RtpDemuxer(transport: makeDummyTransport())

        let fuIndicator: UInt8 = 0x7C
        // End fragment without a preceding start
        let rtp = rtpHeader(marker: true, seq: 1) + [fuIndicator, 0x45, 0xAA, 0xBB]

        var nalEmitted = false
        demuxer.onNalUnit = { _ in nalEmitted = true }

        demuxer.processRtpPacketForTesting(Data(rtp))

        XCTAssertFalse(nalEmitted, "Orphan FU-A end fragment should be discarded")
    }

    // MARK: - Interleaved RTCP Packet (Req 2.3, 11.6)

    /// Channel 1 payloads are forwarded to onRtcpPacket and not to onNalUnit.
    func testInterleavedRtcpPacket() {
        // We test the channel routing logic directly via the interleaved header parser.
        // Since the read loop is async, we verify routing by calling the internal
        // dispatch logic through a thin test shim.

        let demuxer = RtpDemuxer(transport: makeDummyTransport())

        let rtcpPayload = Data([0x80, 0xC9, 0x00, 0x01, 0xDE, 0xAD, 0xBE, 0xEF])

        var receivedRtcp: Data?
        var nalEmitted = false
        demuxer.onRtcpPacket = { data in receivedRtcp = data }
        demuxer.onNalUnit = { _ in nalEmitted = true }

        demuxer.dispatchPayloadForTesting(channel: 1, payload: rtcpPayload)

        XCTAssertEqual(receivedRtcp, rtcpPayload, "RTCP payload should be forwarded to onRtcpPacket")
        XCTAssertFalse(nalEmitted, "RTCP packet should not trigger onNalUnit")
    }

    /// Channel 0 payloads are processed as RTP and not forwarded to onRtcpPacket.
    func testChannel0IsRoutedToRtp() {
        let demuxer = RtpDemuxer(transport: makeDummyTransport())

        let nalPayload: [UInt8] = [0x65, 0x01]
        let rtp = Data(rtpHeader(marker: true) + nalPayload)

        var rtcpEmitted = false
        var nalEmitted = false
        demuxer.onRtcpPacket = { _ in rtcpEmitted = true }
        demuxer.onNalUnit = { _ in nalEmitted = true }

        demuxer.dispatchPayloadForTesting(channel: 0, payload: rtp)

        XCTAssertTrue(nalEmitted, "Channel 0 should route to RTP/NAL processing")
        XCTAssertFalse(rtcpEmitted, "Channel 0 should not trigger onRtcpPacket")
    }

    // MARK: - RTP Statistics (Req 3.2)

    /// onRtpStats is called with updated SSRC, sequence number, and counts.
    func testRtpStatsAreUpdated() {
        let demuxer = RtpDemuxer(transport: makeDummyTransport())

        let nalPayload: [UInt8] = [0x41, 0xAA]
        let rtp = rtpHeader(marker: false, seq: 42, ssrc: 0x12345678) + nalPayload

        var lastStats: RtpStats?
        demuxer.onRtpStats = { stats in lastStats = stats }

        demuxer.processRtpPacketForTesting(Data(rtp))

        XCTAssertNotNil(lastStats)
        XCTAssertEqual(lastStats?.ssrc, 0x12345678)
        XCTAssertEqual(lastStats?.highestSeq, 42)
        XCTAssertEqual(lastStats?.packetCount, 1)
        XCTAssertEqual(lastStats?.octetCount, UInt32(nalPayload.count))
    }

    // MARK: - RTP Header Extension

    /// RTP packets with the X bit set have their extension skipped correctly.
    func testRtpHeaderExtensionIsSkipped() {
        let demuxer = RtpDemuxer(transport: makeDummyTransport())

        // Byte 0: V=2, P=0, X=1, CC=0  →  0x90
        var header: [UInt8] = [0x90, 0x60, 0x00, 0x01,  // V/P/X/CC, M/PT, seq
                                0x00, 0x00, 0x03, 0xE8,  // timestamp
                                0xDE, 0xAD, 0xBE, 0xEF]  // SSRC
        // Extension: profile=0xBEEF, length=1 (1 × 32-bit word = 4 bytes)
        header += [0xBE, 0xEF, 0x00, 0x01,  // profile + length
                   0x00, 0x00, 0x00, 0x00]  // 1 extension word

        let nalPayload: [UInt8] = [0x65, 0xCC]
        let rtp = header + nalPayload

        var receivedNal: Data?
        demuxer.onNalUnit = { unit in receivedNal = unit.data }

        demuxer.processRtpPacketForTesting(Data(rtp))

        XCTAssertEqual(receivedNal, Data(nalPayload), "NAL payload should be extracted after extension")
    }

    // MARK: - Private helper

    /// Creates a dummy transport that is never actually used in unit tests
    /// (tests call internal methods directly).
    private func makeDummyTransport() -> RtspTransport {
        RtspTransport()
    }
}
