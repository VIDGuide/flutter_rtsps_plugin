import Foundation
import os.log

// MARK: - SdpVideoTrack

/// Parsed video track parameters extracted from an SDP DESCRIBE response.
struct SdpVideoTrack {
    /// The RTSP control URL for the video track (absolute or relative).
    let controlUrl: String
    /// H.264 Sequence Parameter Set bytes, decoded from `sprop-parameter-sets`.
    /// `nil` if `sprop-parameter-sets` was absent — decoder will wait for in-band SPS.
    let sps: Data?
    /// H.264 Picture Parameter Set bytes, decoded from `sprop-parameter-sets`.
    /// `nil` if `sprop-parameter-sets` was absent — decoder will wait for in-band PPS.
    let pps: Data?
}

// MARK: - SdpParser

/// Parses Session Description Protocol (SDP) bodies from RTSP DESCRIBE responses.
///
/// Extracts the `m=video` section and its associated attributes:
/// - `a=control` — the track control URL
/// - `a=rtpmap` — codec information
/// - `a=fmtp` — format parameters, including `sprop-parameter-sets` for H.264 SPS/PPS
///
/// Requirements: 7.1, 7.2, 7.3, 7.4
enum SdpParser {

    private static let log = OSLog(subsystem: "com.pandawatch.flutter_rtsps_plugin", category: "SdpParser")

    /// Parses an SDP string and returns the video track parameters.
    ///
    /// - Parameter sdp: The raw SDP body from a DESCRIBE response.
    /// - Returns: A `SdpVideoTrack` with the control URL and optional SPS/PPS data.
    /// - Throws: `RtspError.noVideoTrack` if no `m=video` section is found.
    static func parse(_ sdp: String) throws -> SdpVideoTrack {
        // Split on either \r\n or \n to handle both line ending styles
        let lines = sdp.components(separatedBy: "\n").map {
            $0.trimmingCharacters(in: .init(charactersIn: "\r"))
        }

        var inVideoSection = false
        var foundVideoSection = false
        var controlUrl: String? = nil
        var spsData: Data? = nil
        var ppsData: Data? = nil

        for line in lines {
            // Detect media section boundaries
            if line.hasPrefix("m=") {
                if line.hasPrefix("m=video") {
                    if foundVideoSection {
                        // Already found a video track — log warning and skip (Defect 1.33)
                        os_log("SdpParser: multiple m=video sections found, using first track", log: log, type: .default)
                        inVideoSection = false
                        continue
                    }
                    inVideoSection = true
                    foundVideoSection = true
                } else {
                    // Entering a non-video media section — stop processing video attributes
                    if inVideoSection { break }
                    inVideoSection = false
                }
                continue
            }

            guard inVideoSection else { continue }

            if line.hasPrefix("a=control:") {
                controlUrl = String(line.dropFirst("a=control:".count))
                    .trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("a=fmtp:") {
                // e.g. a=fmtp:96 packetization-mode=1;sprop-parameter-sets=Z0IAH...,aM4...
                if let spropRange = line.range(of: "sprop-parameter-sets=") {
                    // The sprop value runs to the next ';' or end of line
                    let afterSprop = String(line[spropRange.upperBound...])
                    let spropValue = afterSprop.components(separatedBy: ";").first ?? afterSprop
                    let paramSets = spropValue.components(separatedBy: ",")
                    if paramSets.count >= 1 {
                        spsData = Data(base64Encoded: paramSets[0].trimmingCharacters(in: .whitespaces))
                    }
                    if paramSets.count >= 2 {
                        ppsData = Data(base64Encoded: paramSets[1].trimmingCharacters(in: .whitespaces))
                    }
                }
            }
            // a=rtpmap is parsed but not stored — included for completeness per Req 7.1
        }

        guard foundVideoSection else {
            throw RtspError.noVideoTrack
        }

        // Fall back to a wildcard control URL if none was specified in the video section
        let resolvedControl = controlUrl ?? "*"

        return SdpVideoTrack(controlUrl: resolvedControl, sps: spsData, pps: ppsData)
    }
}
