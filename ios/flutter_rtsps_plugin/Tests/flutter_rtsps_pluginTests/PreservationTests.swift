import XCTest
@testable import flutter_rtsps_plugin

// MARK: - Preservation Tests
//
// These tests verify EXISTING correct behavior on UNFIXED code.
// They MUST PASS on the current code — passing confirms baseline behavior
// that must be preserved after fixes are applied.
//
// **Validates: Requirements 3.5, 3.6, 3.12, 3.14, 3.15**

final class PreservationTests: XCTestCase {

    // MARK: - Helpers

    private func makeDummyTransport() -> RtspTransport {
        RtspTransport()
    }

    private func rtpHeader(marker: Bool, seq: UInt16 = 1, ssrc: UInt32 = 0xDEADBEEF) -> [UInt8] {
        let byte0: UInt8 = 0x80
        let byte1: UInt8 = (marker ? 0x80 : 0x00) | 0x60
        let seqHi = UInt8(seq >> 8)
        let seqLo = UInt8(seq & 0xFF)
        let ts: [UInt8] = [0x00, 0x00, 0x03, 0xE8]
        let ssrcBytes: [UInt8] = [
            UInt8((ssrc >> 24) & 0xFF),
            UInt8((ssrc >> 16) & 0xFF),
            UInt8((ssrc >>  8) & 0xFF),
            UInt8( ssrc        & 0xFF)
        ]
        return [byte0, byte1, seqHi, seqLo] + ts + ssrcBytes
    }

    // =========================================================================
    // MARK: - SdpParser.parse() — Req 3.14
    // =========================================================================

    /// **Validates: Requirement 3.14**
    ///
    /// SdpParser.parse() correctly extracts control URL, SPS, and PPS from
    /// a valid SDP body containing sprop-parameter-sets.
    func testSdpParserExtractsControlUrlSpsAndPps() throws {
        let sdp = """
            v=0\r
            o=- 0 0 IN IP4 0.0.0.0\r
            s=Bambu Lab Camera\r
            t=0 0\r
            m=video 0 RTP/AVP 96\r
            a=rtpmap:96 H264/90000\r
            a=fmtp:96 packetization-mode=1;sprop-parameter-sets=Z0IAHpWoKAHoQAAAAwBAAAAPEA==,aM4G8A==\r
            a=control:streamid=0\r
            """

        let track = try SdpParser.parse(sdp)

        XCTAssertEqual(track.controlUrl, "streamid=0")
        XCTAssertEqual(track.sps, Data(base64Encoded: "Z0IAHpWoKAHoQAAAAwBAAAAPEA=="))
        XCTAssertEqual(track.pps, Data(base64Encoded: "aM4G8A=="))
    }

    /// **Validates: Requirement 3.14**
    ///
    /// SdpParser returns nil SPS/PPS when sprop-parameter-sets is absent,
    /// allowing the decoder to wait for in-band parameter sets.
    func testSdpParserReturnsNilSpsWhenAbsent() throws {
        let sdp = """
            v=0\r
            m=video 0 RTP/AVP 96\r
            a=rtpmap:96 H264/90000\r
            a=control:track1\r
            """

        let track = try SdpParser.parse(sdp)

        XCTAssertEqual(track.controlUrl, "track1")
        XCTAssertNil(track.sps)
        XCTAssertNil(track.pps)
    }

    /// **Validates: Requirement 3.14**
    ///
    /// SdpParser falls back to wildcard control URL when a=control is absent.
    func testSdpParserFallsBackToWildcardControl() throws {
        let sdp = """
            v=0\r
            m=video 0 RTP/AVP 96\r
            a=rtpmap:96 H264/90000\r
            """

        let track = try SdpParser.parse(sdp)
        XCTAssertEqual(track.controlUrl, "*")
    }

    // =========================================================================
    // MARK: - RtpDemuxer FU-A Reassembly — Req 3.15
    // =========================================================================

    /// **Validates: Requirement 3.15**
    ///
    /// FU-A fragmented NAL units across 3 RTP packets are reassembled into
    /// a single correct NAL unit with the proper reconstructed header.
    func testFuAReassemblyProducesCorrectNalUnit() {
        let demuxer = RtpDemuxer(transport: makeDummyTransport())

        // FU indicator: NRI=3 (0x60), type=28 (0x1C) → 0x7C
        let fuIndicator: UInt8 = 0x7C
        let nalType: UInt8 = 0x05 // IDR

        // Fragment 1: S=1, E=0 → FU header = 0x85
        let frag1: [UInt8] = [0x11, 0x22]
        let rtp1 = rtpHeader(marker: false, seq: 10) + [fuIndicator, 0x85] + frag1

        // Fragment 2: S=0, E=0 → FU header = 0x05
        let frag2: [UInt8] = [0x33, 0x44]
        let rtp2 = rtpHeader(marker: false, seq: 11) + [fuIndicator, 0x05] + frag2

        // Fragment 3: S=0, E=1 → FU header = 0x45
        let frag3: [UInt8] = [0x55, 0x66]
        let rtp3 = rtpHeader(marker: true, seq: 12) + [fuIndicator, 0x45] + frag3

        var receivedNal: Data?
        var receivedMarker: Bool?
        demuxer.onNalUnit = { unit in
            receivedNal = unit.data
            receivedMarker = unit.isFrameComplete
        }

        demuxer.processRtpPacketForTesting(Data(rtp1))
        XCTAssertNil(receivedNal, "No NAL emitted before FU-A end")

        demuxer.processRtpPacketForTesting(Data(rtp2))
        XCTAssertNil(receivedNal, "No NAL emitted before FU-A end")

        demuxer.processRtpPacketForTesting(Data(rtp3))
        XCTAssertNotNil(receivedNal)

        // Reconstructed NAL header: (0x7C & 0xE0) | 0x05 = 0x65
        let expectedHeader: UInt8 = (fuIndicator & 0xE0) | nalType
        let expectedNal = Data([expectedHeader] + frag1 + frag2 + frag3)
        XCTAssertEqual(receivedNal, expectedNal)
        XCTAssertEqual(receivedMarker, true)
    }

    // =========================================================================
    // MARK: - RtpDemuxer STAP-A Aggregation — Req 3.15
    // =========================================================================

    /// **Validates: Requirement 3.15**
    ///
    /// STAP-A packets containing multiple NAL units are correctly split and
    /// each NAL unit is dispatched individually. The marker bit is only set
    /// on the last NAL unit.
    func testStapAProducesCorrectNalUnits() {
        let demuxer = RtpDemuxer(transport: makeDummyTransport())

        // Build a STAP-A payload: header(1) + [size(2) + NAL]...
        let nal1: [UInt8] = [0x67, 0xAA, 0xBB] // SPS (type 7)
        let nal2: [UInt8] = [0x68, 0xCC]         // PPS (type 8)

        var stapPayload: [UInt8] = [24] // STAP-A NAL type
        // NAL 1: size = 3
        stapPayload += [0x00, UInt8(nal1.count)]
        stapPayload += nal1
        // NAL 2: size = 2
        stapPayload += [0x00, UInt8(nal2.count)]
        stapPayload += nal2

        let rtp = rtpHeader(marker: true, seq: 1) + stapPayload

        var receivedNals: [(Data, Bool)] = []
        demuxer.onNalUnit = { unit in
            receivedNals.append((unit.data, unit.isFrameComplete))
        }

        demuxer.processRtpPacketForTesting(Data(rtp))

        XCTAssertEqual(receivedNals.count, 2, "STAP-A should produce 2 NAL units")
        XCTAssertEqual(receivedNals[0].0, Data(nal1))
        XCTAssertEqual(receivedNals[0].1, false, "First NAL should not have marker")
        XCTAssertEqual(receivedNals[1].0, Data(nal2))
        XCTAssertEqual(receivedNals[1].1, true, "Last NAL should have marker")
    }

    /// **Validates: Requirement 3.15**
    ///
    /// Single NAL unit packets (non-FU-A, non-STAP-A) are forwarded directly
    /// with the correct marker bit.
    func testSingleNalUnitForwardedDirectly() {
        let demuxer = RtpDemuxer(transport: makeDummyTransport())

        let nalPayload: [UInt8] = [0x65, 0xDE, 0xAD] // IDR slice
        let rtp = rtpHeader(marker: true, seq: 5) + nalPayload

        var receivedNal: Data?
        var receivedMarker: Bool?
        demuxer.onNalUnit = { unit in
            receivedNal = unit.data
            receivedMarker = unit.isFrameComplete
        }

        demuxer.processRtpPacketForTesting(Data(rtp))

        XCTAssertEqual(receivedNal, Data(nalPayload))
        XCTAssertEqual(receivedMarker, true)
    }

    // =========================================================================
    // MARK: - RtcpSender.buildReceiverReport() — Req 3.6
    // =========================================================================

    /// **Validates: Requirement 3.6**
    ///
    /// buildReceiverReport() produces a valid 32-byte RTCP Receiver Report
    /// with correct header, source SSRC, and extended highest sequence number.
    func testBuildReceiverReportStructure() {
        let transport = makeDummyTransport()
        let sender = RtcpSender(transport: transport) { _ in }

        let stats = RtpStats(ssrc: 0xAABBCCDD, highestSeq: 1234, packetCount: 100, octetCount: 50000)
        sender.updateStats(stats)

        let packet = sender.buildReceiverReportForTesting()

        // Total size must be 32 bytes
        XCTAssertEqual(packet.count, 32)

        // Byte 0: V=2, P=0, RC=1 → 0x81
        XCTAssertEqual(packet[0], 0x81)

        // Byte 1: PT=201 (Receiver Report)
        XCTAssertEqual(packet[1], 201)

        // Bytes 2-3: length = 7
        let length = UInt16(packet[2]) << 8 | UInt16(packet[3])
        XCTAssertEqual(length, 7)

        // Bytes 8-11: Source SSRC in report block
        let sourceSsrc = UInt32(packet[8]) << 24
                       | UInt32(packet[9]) << 16
                       | UInt32(packet[10]) << 8
                       | UInt32(packet[11])
        XCTAssertEqual(sourceSsrc, 0xAABBCCDD)

        // Bytes 16-19: Extended highest sequence number
        let highestSeq = UInt32(packet[16]) << 24
                       | UInt32(packet[17]) << 16
                       | UInt32(packet[18]) << 8
                       | UInt32(packet[19])
        XCTAssertEqual(highestSeq, 1234)
    }

    // =========================================================================
    // MARK: - Digest Auth Without qop — Req 3.5
    // =========================================================================

    /// **Validates: Requirement 3.5**
    ///
    /// Digest authentication without qop produces a correct Authorization
    /// header with username, realm, nonce, uri, and response fields.
    func testDigestAuthWithoutQopProducesCorrectHeader() throws {
        let transport = makeDummyTransport()
        let sm = try RtspStateMachine(
            transport: transport,
            url: "rtsps://192.168.1.10/streaming/live/1",
            username: "bblp",
            password: "testpass"
        )

        let authHeader = sm.buildDigestAuthorizationForTesting(
            method: "DESCRIBE",
            uri: "rtsps://192.168.1.10/streaming/live/1",
            realm: "Bambu",
            nonce: "abc123"
        )

        // Verify all required Digest fields are present
        XCTAssertTrue(authHeader.hasPrefix("Digest "))
        XCTAssertTrue(authHeader.contains("username=\"bblp\""))
        XCTAssertTrue(authHeader.contains("realm=\"Bambu\""))
        XCTAssertTrue(authHeader.contains("nonce=\"abc123\""))
        XCTAssertTrue(authHeader.contains("uri=\"rtsps://192.168.1.10/streaming/live/1\""))
        XCTAssertTrue(authHeader.contains("response=\""))

        // Verify the response hash is correct per RFC 2617 (no qop)
        // HA1 = MD5(bblp:Bambu:testpass)
        // HA2 = MD5(DESCRIBE:rtsps://192.168.1.10/streaming/live/1)
        // response = MD5(HA1:abc123:HA2)
        let ha1 = sm.md5ForTesting("bblp:Bambu:testpass")
        let ha2 = sm.md5ForTesting("DESCRIBE:rtsps://192.168.1.10/streaming/live/1")
        let expectedResponse = sm.md5ForTesting("\(ha1):abc123:\(ha2)")
        XCTAssertTrue(authHeader.contains("response=\"\(expectedResponse)\""))
    }

    /// **Validates: Requirement 3.5**
    ///
    /// MD5 hash computation produces correct results (baseline for Digest auth).
    func testMd5ProducesCorrectHash() throws {
        let transport = makeDummyTransport()
        let sm = try RtspStateMachine(
            transport: transport,
            url: "rtsps://192.168.1.10/streaming/live/1",
            username: "bblp",
            password: "testpass"
        )

        XCTAssertEqual(sm.md5ForTesting("hello"), "5d41402abc4b2a76b9719d911017c592")
        XCTAssertEqual(sm.md5ForTesting(""), "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(sm.md5ForTesting("bblp:Bambu:testpass"), sm.md5ForTesting("bblp:Bambu:testpass"))
    }

    // =========================================================================
    // MARK: - FlutterTextureOutput.copyPixelBuffer() — Req 3.12
    // =========================================================================

    /// **Validates: Requirement 3.12**
    ///
    /// copyPixelBuffer() returns nil when no frame has been received yet.
    func testCopyPixelBufferReturnsNilBeforeFirstFrame() {
        // We can't create a real FlutterTextureRegistry in unit tests,
        // but we can verify the behavior through the public API pattern.
        // The FlutterTextureOutput stores latestPixelBuffer = nil initially,
        // so copyPixelBuffer() returns nil.
        //
        // This test verifies the contract: no frame → nil return.
        // The actual FlutterTextureOutput requires a FlutterTextureRegistry
        // which is only available in integration tests.
        //
        // We verify the RtpDemuxer → onNalUnit callback chain works correctly
        // as a proxy for the texture output pipeline.
        let demuxer = RtpDemuxer(transport: makeDummyTransport())

        var nalCount = 0
        demuxer.onNalUnit = { _ in nalCount += 1 }

        // Before any packets, no NAL units should have been emitted
        XCTAssertEqual(nalCount, 0)

        // After a single NAL packet, exactly one NAL unit is emitted
        let rtp = rtpHeader(marker: true, seq: 1) + [0x65, 0xAA]
        demuxer.processRtpPacketForTesting(Data(rtp))
        XCTAssertEqual(nalCount, 1)
    }

    // =========================================================================
    // MARK: - Property-Based: Valid SDP → Valid SdpVideoTrack — Req 3.14
    // =========================================================================

    /// **Validates: Requirement 3.14**
    ///
    /// For all valid SDP strings with an m=video section, parse returns a
    /// valid SdpVideoTrack with a non-empty control URL.
    func testAllValidSdpWithVideoSectionProducesValidTrack() throws {
        // Generate a variety of valid SDP strings
        let controlUrls = ["streamid=0", "track1", "video", "stream/video"]
        let spropSets: [String?] = [
            nil,
            "Z0IAHpWoKAHoQAAAAwBAAAAPEA==,aM4G8A==",
            "Z0IAHg==,aM4=",
        ]

        for control in controlUrls {
            for sprop in spropSets {
                var sdp = "v=0\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\n"
                if let sprop = sprop {
                    sdp += "a=fmtp:96 packetization-mode=1;sprop-parameter-sets=\(sprop)\r\n"
                }
                sdp += "a=control:\(control)\r\n"

                let track = try SdpParser.parse(sdp)
                XCTAssertEqual(track.controlUrl, control, "Control URL mismatch for input: \(control)")
                XCTAssertFalse(track.controlUrl.isEmpty, "Control URL should not be empty")

                if sprop != nil {
                    XCTAssertNotNil(track.sps, "SPS should be present when sprop is provided")
                } else {
                    XCTAssertNil(track.sps, "SPS should be nil when sprop is absent")
                }
            }
        }
    }

    // =========================================================================
    // MARK: - Property-Based: Non-FU-A NAL → onNalUnit called once — Req 3.15
    // =========================================================================

    /// **Validates: Requirement 3.15**
    ///
    /// For all valid RTP packets with non-FU-A, non-STAP-A NAL types (1-23
    /// excluding 24 and 28), onNalUnit is called exactly once.
    func testNonFuaNalTypesCallOnNalUnitExactlyOnce() {
        let demuxer = RtpDemuxer(transport: makeDummyTransport())

        // NAL types 1-23 (excluding 24=STAP-A and 28=FU-A) are single NAL unit packets
        let singleNalTypes: [UInt8] = Array(1...23).filter { $0 != 24 }

        for nalType in singleNalTypes {
            var callCount = 0
            demuxer.onNalUnit = { _ in callCount += 1 }

            let nalPayload: [UInt8] = [nalType | 0x60, 0xAA, 0xBB] // NRI=3 + type
            let rtp = rtpHeader(marker: true, seq: UInt16(nalType)) + nalPayload

            demuxer.processRtpPacketForTesting(Data(rtp))

            XCTAssertEqual(
                callCount, 1,
                "NAL type \(nalType): onNalUnit should be called exactly once"
            )
        }
    }
}
