import Foundation

// MARK: - AccessUnit

/// A complete H.264 video frame consisting of one or more NAL units,
/// delimited by the RTP marker bit. Ready for buffering and decode.
struct AccessUnit {
    /// All NAL units comprising this frame, in RTP arrival order.
    let nalUnits: [Data]
    /// RTP timestamp from the final RTP packet (marker bit set).
    let rtpTimestamp: UInt32
    /// RTP sequence number of the final packet (for UDP reordering).
    /// UInt16 per RFC 3550 §5.1 — matches the RTP header field width.
    let sequenceNumber: UInt16
    /// Wall-clock arrival time (ProcessInfo.systemUptime).
    let arrivalTime: TimeInterval
    /// True if any NAL unit is an IDR slice (NAL type 5).
    let isIDR: Bool

    /// Total byte size of all NAL units.
    var byteSize: Int { nalUnits.reduce(0) { $0 + $1.count } }
}

// MARK: - TransportMode

/// Selects jitter buffer behavior: TCP = FIFO delivery smoothing,
/// UDP = sequence-number reordering with playout deadline.
enum TransportMode {
    case tcp
    case udp
}

// MARK: - JitterBufferConfig

/// Configuration for the jitter buffer. Buffer depth is clamped to [50, 1000] ms.
struct JitterBufferConfig {
    /// Target buffer depth in milliseconds. Clamped to [50, 1000].
    var bufferDepthMs: Int
    /// Transport mode determines ordering behavior.
    var transportMode: TransportMode
    /// Enable adaptive buffer depth adjustment (Req 13, nice-to-have).
    var adaptiveEnabled: Bool

    /// Clamps bufferDepthMs to [50, 1000] range (Req 12.3).
    /// Defaults to 150ms for TCP, 300ms for UDP.
    init(bufferDepthMs: Int? = nil, transportMode: TransportMode, adaptiveEnabled: Bool = false) {
        let defaultDepth = transportMode == .tcp ? 150 : 300
        let raw = bufferDepthMs ?? defaultDepth
        self.bufferDepthMs = max(50, min(1000, raw))
        self.transportMode = transportMode
        self.adaptiveEnabled = adaptiveEnabled
    }
}

// MARK: - JitterBufferStats

/// Snapshot of jitter buffer diagnostics (Req 10).
struct JitterBufferStats {
    /// Current effective buffer depth in milliseconds.
    var currentBufferDepthMs: Double = 0
    /// Number of frames currently held in the buffer.
    var framesBuffered: Int = 0
    /// Cumulative frames enqueued since session start.
    var totalFramesReceived: UInt64 = 0
    /// Cumulative frames dropped (overflow, stale, etc.).
    var totalFramesDropped: UInt64 = 0
    /// Cumulative frames released via onReleaseFrame.
    var totalFramesReleased: UInt64 = 0
    /// Number of burst events detected (3+ frames within 5ms).
    var totalBurstEvents: UInt64 = 0
    /// Current output frame rate in fps.
    var currentOutputFps: Double = 0
    /// Average burst size across all detected bursts.
    var averageBurstSize: Double = 0
    /// Maximum burst size observed in the current session.
    var maxBurstSize: Int = 0
    /// Number of times the jitter buffer was reset (reconnections).
    var sessionResetCount: UInt64 = 0
    /// Current adaptive buffer depth in milliseconds (Req 13.4).
    /// Zero when adaptive mode is disabled.
    var currentAdaptiveDepthMs: Int = 0
}

// MARK: - StreamHealthEvent

/// Stream health events reported via the optional callback (Req 15).
enum StreamHealthEvent {
    /// A burst of frames arrived (3+ within 5ms).
    case burst(size: Int, durationMs: Double)
    /// The buffer underran — playback stalled.
    case stall(timestamp: TimeInterval)
    /// Recovered from a stall after the given duration.
    case recovery(stallDurationMs: Double)
}
