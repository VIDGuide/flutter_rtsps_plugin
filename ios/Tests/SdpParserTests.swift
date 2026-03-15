import XCTest

// SdpParser and SdpVideoTrack are defined in the plugin's Classes/ directory.
// When wired into an Xcode test target, add both SdpParser.swift and
// RtspTransport.swift (for RtspError) to the target's compile sources.

final class SdpParserTests: XCTestCase {

    // MARK: - Valid SDP with sprop-parameter-sets

    /// Validates Requirements 7.1 and 7.2:
    /// Parser extracts control URL and decodes SPS/PPS from sprop-parameter-sets.
    func testValidSdpWithSpropParameterSets() throws {
        // Realistic Bambu-style SDP
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

        // SPS: base64 "Z0IAHpWoKAHoQAAAAwBAAAAPEA==" should decode to non-empty data
        let expectedSps = Data(base64Encoded: "Z0IAHpWoKAHoQAAAAwBAAAAPEA==")
        XCTAssertNotNil(track.sps)
        XCTAssertEqual(track.sps, expectedSps)

        // PPS: base64 "aM4G8A==" should decode to non-empty data
        let expectedPps = Data(base64Encoded: "aM4G8A==")
        XCTAssertNotNil(track.pps)
        XCTAssertEqual(track.pps, expectedPps)
    }

    // MARK: - SDP with only audio track (no video)

    /// Validates Requirement 7.3:
    /// Parser throws noVideoTrack when no m=video section is present.
    func testSdpWithoutVideoTrackThrows() {
        let sdp = """
            v=0\r
            o=- 0 0 IN IP4 0.0.0.0\r
            s=Audio Only\r
            t=0 0\r
            m=audio 0 RTP/AVP 0\r
            a=rtpmap:0 PCMU/8000\r
            a=control:streamid=audio\r
            """

        XCTAssertThrowsError(try SdpParser.parse(sdp)) { error in
            guard let rtspError = error as? RtspError,
                  case .noVideoTrack = rtspError else {
                XCTFail("Expected RtspError.noVideoTrack, got \(error)")
                return
            }
        }
    }

    // MARK: - SDP with video track but no sprop-parameter-sets

    /// Validates Requirement 7.4:
    /// Parser returns nil sps/pps (not an error) when sprop-parameter-sets is absent.
    func testSdpWithVideoButNoSpropParameterSets() throws {
        let sdp = """
            v=0\r
            o=- 0 0 IN IP4 0.0.0.0\r
            s=Stream\r
            t=0 0\r
            m=video 0 RTP/AVP 96\r
            a=rtpmap:96 H264/90000\r
            a=fmtp:96 packetization-mode=1\r
            a=control:track0\r
            """

        let track = try SdpParser.parse(sdp)

        XCTAssertEqual(track.controlUrl, "track0")
        XCTAssertNil(track.sps, "sps should be nil when sprop-parameter-sets is absent")
        XCTAssertNil(track.pps, "pps should be nil when sprop-parameter-sets is absent")
    }

    // MARK: - Additional edge cases

    /// Parser stops collecting video attributes when a subsequent m= section begins.
    func testVideoAttributesNotLeakedFromSubsequentSection() throws {
        let sdp = """
            v=0\r
            m=video 0 RTP/AVP 96\r
            a=rtpmap:96 H264/90000\r
            a=fmtp:96 packetization-mode=1;sprop-parameter-sets=Z0IAHpWoKAHoQAAAAwBAAAAPEA==,aM4G8A==\r
            a=control:videotrack\r
            m=audio 0 RTP/AVP 0\r
            a=control:audiotrack\r
            """

        let track = try SdpParser.parse(sdp)
        XCTAssertEqual(track.controlUrl, "videotrack")
        XCTAssertNotNil(track.sps)
    }

    /// Parser handles LF-only line endings (no CR).
    func testLfOnlyLineEndings() throws {
        let sdp = "v=0\nm=video 0 RTP/AVP 96\na=rtpmap:96 H264/90000\na=control:track1\n"

        let track = try SdpParser.parse(sdp)
        XCTAssertEqual(track.controlUrl, "track1")
        XCTAssertNil(track.sps)
        XCTAssertNil(track.pps)
    }

    /// Completely empty SDP throws noVideoTrack.
    func testEmptySdpThrows() {
        XCTAssertThrowsError(try SdpParser.parse("")) { error in
            guard let rtspError = error as? RtspError,
                  case .noVideoTrack = rtspError else {
                XCTFail("Expected RtspError.noVideoTrack, got \(error)")
                return
            }
        }
    }
}
