import Foundation

// MARK: - RtpNalUnit

/// Typed container for NAL unit data extracted from an RTP packet.
/// Replaces the positional `(Data, Bool)` tuple in `RtpDemuxer.onNalUnit`,
/// improving readability and making future additions non-breaking.
///
/// - Requirements: 3.7, 6.1, 6.2
struct RtpNalUnit {
    /// The raw NAL unit payload (including the NAL header byte).
    let data: Data
    /// True when the RTP marker bit was set, indicating the access unit
    /// (video frame) is complete.
    let isFrameComplete: Bool
    /// RTP timestamp from the packet header (90 kHz clock for H.264 video).
    let rtpTimestamp: UInt32
    /// RTP sequence number — UInt16 per RFC 3550 §5.1.
    let sequenceNumber: UInt16
}
