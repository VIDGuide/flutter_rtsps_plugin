import Foundation
import os.log

// MARK: - JitterBuffer

/// Frame-level jitter buffer that absorbs bursty RTP delivery and releases
/// complete `AccessUnit` values at steady intervals derived from RTP timestamps.
///
/// - TCP mode: FIFO delivery smoothing — frames released in arrival order,
///   RTP timestamps used for output timing only.
/// - UDP mode: Sequence-number reordering with playout deadline — frames
///   insertion-sorted by `sequenceNumber` using wraparound-safe comparison.
///
/// Thread safety: `os_unfair_lock` protects the buffer array and all mutable
/// state. The release timer fires on a dedicated serial `jitterQueue`.
///
/// Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 2.1, 2.2, 2.3, 2.5,
///               9.2, 9.4, 10.1, 10.3
final class JitterBuffer {

    // MARK: - Constants

    /// Frames with RTP timestamp more than 270,000 ticks (3s × 90kHz) behind
    /// the current playout position are discarded as stale. (Req 2.4)
    static let staleThresholdTicks: UInt32 = 270_000

    // MARK: - Configuration

    /// Configuration (immutable after init).
    let config: JitterBufferConfig

    // MARK: - Callbacks

    /// Called on the jitter queue when a frame is ready for decode.
    var onReleaseFrame: ((AccessUnit) -> Void)?

    /// Stream health callback (Req 15, optional). Set by task 5.x.
    var onStreamHealth: ((StreamHealthEvent) -> Void)?

    // MARK: - Private State (protected by _lock)

    private var _lock = os_unfair_lock()

    /// The frame buffer. TCP: append-only FIFO. UDP: insertion-sorted by sequence number.
    private var buffer: [AccessUnit] = []

    /// Base RTP timestamp of the first frame in the current session (for playout offset).
    private var baseRtpTimestamp: UInt32?

    /// Base wall-clock time corresponding to `baseRtpTimestamp`.
    private var baseWallClock: TimeInterval?

    /// RTP timestamp of the previously released frame (for delta computation).
    private var lastReleasedTimestamp: UInt32?

    /// Exponential moving average of inter-frame RTP timestamp deltas (in seconds).
    /// Gain 1/16 per RFC 3550 convention (Req 2.5).
    private var emaInterval: Double?

    /// True while in the initial buffering period or recovering from underrun (Req 1.9).
    private var isBuffering: Bool = true

    /// Wall-clock time when the first frame was enqueued after an underrun.
    private var bufferingStartTime: TimeInterval?

    /// Cumulative frames released via `onReleaseFrame`.
    private var _totalFramesReleased: UInt64 = 0

    /// Mutable stats snapshot (protected by _lock).
    private var _stats = JitterBufferStats()

    // MARK: - Burst Detection State (protected by _lock, Req 10.2, 14.1, 14.2)

    /// Sliding window of recent frame arrival times for burst detection.
    /// A burst is 3+ frames arriving within 5ms.
    private var recentArrivalTimes: [TimeInterval] = []

    /// Burst detection window in seconds (5ms).
    private static let burstWindowSeconds: TimeInterval = 0.005

    /// Minimum frames within the burst window to classify as a burst.
    private static let burstMinFrames = 3

    /// Running sum of burst sizes for computing `averageBurstSize`.
    private var totalBurstFrames: UInt64 = 0

    // MARK: - Stall/Recovery Tracking (protected by _lock, Req 15.1, 15.2)

    /// Wall-clock time when the most recent stall (underrun) began.
    /// Set when the buffer empties during release; cleared on recovery.
    private var stallStartTime: TimeInterval?

    // MARK: - Adaptive Buffer Depth State (protected by _lock, Req 13.1–13.4)

    /// Current adaptive buffer depth in milliseconds. Starts at `config.bufferDepthMs`.
    /// Adjusted up on burst events (+20%) and down when jitter is stable (-10%).
    private var adaptiveDepthMs: Int = 0

    /// Sliding window of inter-arrival jitter samples (seconds) over the last 30s.
    /// Each sample is the absolute difference between consecutive inter-arrival intervals.
    private var jitterSamples: [(timestamp: TimeInterval, jitter: Double)] = []

    /// Wall-clock time when jitter first dropped below 50% of the adaptive depth.
    /// Reset to nil whenever jitter exceeds the threshold. After 10 consecutive
    /// seconds below threshold, the depth is decreased by 10%.
    private var stableJitterStart: TimeInterval?

    /// Arrival time of the previous frame, used to compute inter-arrival intervals
    /// for the adaptive jitter measurement.
    private var lastArrivalTime: TimeInterval?

    /// Previous inter-arrival interval, used to compute jitter (variation between
    /// consecutive inter-arrival intervals).
    private var lastInterArrivalInterval: Double?

    /// Sliding window duration for jitter measurement (30 seconds, Req 13.1).
    private static let jitterWindowSeconds: TimeInterval = 30.0

    /// Duration of stable jitter required before decreasing depth (10 seconds, Req 13.2).
    private static let stableJitterDurationSeconds: TimeInterval = 10.0

    // MARK: - Timer

    private var timer: DispatchSourceTimer?
    private let jitterQueue = DispatchQueue(label: "com.pandawatch.rtsps.jitterBuffer",
                                            qos: .userInteractive)

    private static let log = OSLog(subsystem: "com.pandawatch.rtsps",
                                   category: "JitterBuffer")

    // MARK: - Init

    init(config: JitterBufferConfig) {
        self.config = config
        self.adaptiveDepthMs = config.bufferDepthMs
    }

    deinit {
        timer?.cancel()
        timer = nil
    }

    // MARK: - Public API

    /// Current statistics snapshot (synchronous read, Req 10.3).
    var stats: JitterBufferStats {
        withLock {
            var s = _stats
            s.framesBuffered = buffer.count
            s.totalFramesReleased = _totalFramesReleased
            s.currentAdaptiveDepthMs = config.adaptiveEnabled ? adaptiveDepthMs : 0
            return s
        }
    }

    /// The effective buffer depth, accounting for adaptive mode (Req 13).
    /// Returns `adaptiveDepthMs` when adaptive is enabled, otherwise `config.bufferDepthMs`.
    /// Must be called while holding `_lock`.
    private var effectiveDepthMs: Int {
        config.adaptiveEnabled ? adaptiveDepthMs : config.bufferDepthMs
    }

    /// Enqueue a complete access unit. Thread-safe (os_unfair_lock).
    ///
    /// - TCP mode: appends to the end (FIFO). (Req 1.2)
    /// - UDP mode: insertion-sorted by sequence number using wraparound-safe
    ///   signed 16-bit comparison. (Req 1.3, 9.2)
    func enqueue(_ accessUnit: AccessUnit) {
        var burstEvent: StreamHealthEvent?

        withLock {
            _stats.totalFramesReceived += 1

            // Stale frame discard: if the frame's RTP timestamp is more than
            // 270,000 ticks (3s) behind the current playout position, drop it. (Req 2.4)
            if let current = lastReleasedTimestamp {
                let age = Int32(bitPattern: current &- accessUnit.rtpTimestamp)
                if age > Int32(Self.staleThresholdTicks) {
                    _stats.totalFramesDropped += 1
                    os_log("JitterBuffer: discarding stale frame (age=%d ticks, threshold=%d)",
                           log: Self.log, type: .info,
                           age, Self.staleThresholdTicks)
                    return
                }
            }

            switch config.transportMode {
            case .tcp:
                // FIFO — append in arrival order, trust TCP for ordering.
                buffer.append(accessUnit)

            case .udp:
                // Insertion-sort by sequence number (wraparound-safe).
                let insertIndex = buffer.lastIndex(where: { existing in
                    // Positive result means `existing` comes before `accessUnit`.
                    Int16(bitPattern: accessUnit.sequenceNumber &- existing.sequenceNumber) > 0
                }).map { $0 + 1 } ?? findUDPInsertionIndex(for: accessUnit)
                buffer.insert(accessUnit, at: insertIndex)
            }

            // Check for overflow after insertion. (Req 1.8)
            handleOverflow()

            // Burst detection: track arrival times in a sliding window. (Req 10.2, 14.1, 14.2)
            burstEvent = detectBurst()

            // Adaptive depth: measure jitter and adjust depth. (Req 13.1, 13.2)
            updateAdaptiveDepth(arrivalTime: accessUnit.arrivalTime)

            // If we're in the buffering period, record when the first frame arrived.
            if isBuffering && bufferingStartTime == nil {
                bufferingStartTime = ProcessInfo.processInfo.systemUptime
            }
        }

        // Invoke stream health callback outside the lock to avoid deadlock. (Req 15.1, 15.2)
        if let event = burstEvent {
            onStreamHealth?(event)
        }
    }

    /// Start the release timer. Call after pipeline is wired.
    func start() {
        jitterQueue.async { [weak self] in
            self?.startTimer()
        }
    }

    /// Stop the release timer and drain the buffer.
    func stop() {
        jitterQueue.sync { [weak self] in
            self?.stopTimer()
        }
        withLock {
            buffer.removeAll()
        }
    }

    /// Reset state for reconnection (clear buffer, reset timestamps, EMA).
    ///
    /// Does NOT increment `totalFramesDropped` — reconnection is a normal
    /// operation, not a drop event. Increments `sessionResetCount` for
    /// diagnostics. (Req 9.4)
    func reset() {
        withLock {
            buffer.removeAll()
            baseRtpTimestamp = nil
            baseWallClock = nil
            lastReleasedTimestamp = nil
            emaInterval = nil
            isBuffering = true
            bufferingStartTime = nil
            recentArrivalTimes.removeAll()
            stallStartTime = nil
            // Reset adaptive state back to configured depth. (Req 13)
            adaptiveDepthMs = config.bufferDepthMs
            jitterSamples.removeAll()
            stableJitterStart = nil
            lastArrivalTime = nil
            lastInterArrivalInterval = nil
            _stats.sessionResetCount += 1
        }
    }

    // MARK: - Lock Helper

    /// Executes `body` while holding `os_unfair_lock`.
    private func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return body()
    }

    // MARK: - UDP Insertion Sort Helper

    /// Finds the correct insertion index for a UDP access unit when the
    /// `lastIndex(where:)` fast path doesn't find a match (i.e., the new
    /// frame belongs at the beginning of the buffer).
    private func findUDPInsertionIndex(for accessUnit: AccessUnit) -> Int {
        // Linear scan from the front — the frame belongs before the first
        // element that is "after" it in sequence-number order.
        for (i, existing) in buffer.enumerated() {
            if Int16(bitPattern: accessUnit.sequenceNumber &- existing.sequenceNumber) < 0 {
                return i
            }
        }
        return buffer.count
    }

    // MARK: - Overflow Handling (Req 1.8)

    /// Drops frames when the buffer exceeds 2× `bufferDepthMs` worth of frames.
    ///
    /// Strategy: drop oldest non-IDR frames first. If the buffer still exceeds
    /// the limit (degenerate all-IDR case), drop oldest IDR frames. The buffer
    /// must always return to at or below 2× depth after overflow handling.
    ///
    /// Must be called while holding `_lock`.
    private func handleOverflow() {
        // Max allowed frames: 2× effectiveDepthMs at ~30fps (~33ms per frame).
        let maxAllowedFrames = max(1, (2 * effectiveDepthMs) / 33)

        guard buffer.count > maxAllowedFrames else { return }

        let framesToDrop = buffer.count - maxAllowedFrames

        os_log("JitterBuffer: overflow detected (%d frames, max %d), dropping %d",
               log: Self.log, type: .info,
               buffer.count, maxAllowedFrames, framesToDrop)

        var dropped = 0

        // Pass 1: Drop oldest non-IDR frames first.
        var i = 0
        while dropped < framesToDrop && i < buffer.count {
            if !buffer[i].isIDR {
                buffer.remove(at: i)
                dropped += 1
                // Don't increment i — next element shifted into this position.
            } else {
                i += 1
            }
        }

        // Pass 2: If still over limit (all remaining are IDR), drop oldest IDR frames.
        while buffer.count > maxAllowedFrames {
            buffer.removeFirst()
            dropped += 1
        }

        _stats.totalFramesDropped += UInt64(dropped)
    }

    // MARK: - Burst Detection (Req 10.2, 14.1, 14.2)

    /// Checks if the current frame arrival constitutes a burst event.
    /// A burst is 3+ frames arriving within a 5ms window.
    ///
    /// Must be called while holding `_lock`.
    /// - Returns: A `.burst` health event if a burst was detected, nil otherwise.
    private func detectBurst() -> StreamHealthEvent? {
        let now = ProcessInfo.processInfo.systemUptime
        recentArrivalTimes.append(now)

        // Trim arrival times outside the sliding window.
        let windowStart = now - Self.burstWindowSeconds
        while let first = recentArrivalTimes.first, first < windowStart {
            recentArrivalTimes.removeFirst()
        }

        // Check if we have enough frames in the window to classify as a burst.
        guard recentArrivalTimes.count >= Self.burstMinFrames else { return nil }

        let burstSize = recentArrivalTimes.count
        let durationMs = (recentArrivalTimes.last! - recentArrivalTimes.first!) * 1000.0

        // Update burst stats.
        _stats.totalBurstEvents += 1
        totalBurstFrames += UInt64(burstSize)
        _stats.averageBurstSize = Double(totalBurstFrames) / Double(_stats.totalBurstEvents)
        _stats.maxBurstSize = max(_stats.maxBurstSize, burstSize)

        // Clear the window so the same frames don't trigger another burst event.
        recentArrivalTimes.removeAll()

        os_log("JitterBuffer: burst detected (size=%d, duration=%.1fms)",
               log: Self.log, type: .info, burstSize, durationMs)

        // Adaptive mode: increase depth by 20% on burst, clamped to 1000ms. (Req 13.3)
        if config.adaptiveEnabled {
            let increased = Int(Double(adaptiveDepthMs) * 1.2)
            adaptiveDepthMs = min(increased, 1000)
            // Reset stable jitter tracking since conditions changed.
            stableJitterStart = nil
            os_log("JitterBuffer: adaptive depth increased to %dms (burst)",
                   log: Self.log, type: .info, adaptiveDepthMs)
        }

        return .burst(size: burstSize, durationMs: durationMs)
    }

    // MARK: - Adaptive Buffer Depth (Req 13.1, 13.2, 13.3, 13.4)

    /// Updates the adaptive buffer depth based on measured inter-arrival jitter.
    /// Measures jitter over a 30s sliding window. When jitter stays below 50%
    /// of the current adaptive depth for 10 consecutive seconds, decreases
    /// depth by 10% (clamped to 50ms minimum).
    ///
    /// Must be called while holding `_lock`.
    private func updateAdaptiveDepth(arrivalTime: TimeInterval) {
        guard config.adaptiveEnabled else { return }

        // Compute inter-arrival interval.
        defer { lastArrivalTime = arrivalTime }
        guard let prevArrival = lastArrivalTime else { return }
        let interArrival = arrivalTime - prevArrival
        guard interArrival > 0 else { return }

        // Compute jitter as variation between consecutive inter-arrival intervals.
        defer { lastInterArrivalInterval = interArrival }
        guard let prevInterval = lastInterArrivalInterval else { return }
        let jitter = abs(interArrival - prevInterval)

        // Add to sliding window and trim samples older than 30s.
        jitterSamples.append((timestamp: arrivalTime, jitter: jitter))
        let windowStart = arrivalTime - Self.jitterWindowSeconds
        while let first = jitterSamples.first, first.timestamp < windowStart {
            jitterSamples.removeFirst()
        }

        // Compute average jitter over the window.
        guard !jitterSamples.isEmpty else { return }
        let avgJitter = jitterSamples.reduce(0.0) { $0 + $1.jitter } / Double(jitterSamples.count)

        // Convert adaptive depth to seconds for comparison.
        let depthSeconds = Double(adaptiveDepthMs) / 1000.0
        let threshold = depthSeconds * 0.5

        if avgJitter < threshold {
            // Jitter is below 50% of depth — track stability duration.
            if stableJitterStart == nil {
                stableJitterStart = arrivalTime
            }
            if let stableStart = stableJitterStart,
               (arrivalTime - stableStart) >= Self.stableJitterDurationSeconds {
                // Stable for 10+ seconds — decrease depth by 10%, clamped to 50ms. (Req 13.2)
                let decreased = Int(Double(adaptiveDepthMs) * 0.9)
                adaptiveDepthMs = max(decreased, 50)
                // Reset stable tracking to require another 10s before next decrease.
                stableJitterStart = arrivalTime
                os_log("JitterBuffer: adaptive depth decreased to %dms (stable jitter)",
                       log: Self.log, type: .info, adaptiveDepthMs)
            }
        } else {
            // Jitter exceeded threshold — reset stability tracking.
            stableJitterStart = nil
        }
    }

    // MARK: - Timer Management

    /// Creates and starts the release timer on `jitterQueue`.
    /// Must be called on `jitterQueue`.
    private func startTimer() {
        stopTimer()

        let t = DispatchSource.makeTimerSource(queue: jitterQueue)
        // Start with a short polling interval; the release callback will
        // reschedule based on RTP timestamp deltas once frames flow.
        let initialInterval = withLock { Double(effectiveDepthMs) / 1000.0 }
        t.schedule(deadline: .now() + initialInterval, repeating: .milliseconds(1),
                   leeway: .microseconds(500))
        t.setEventHandler { [weak self] in
            self?.releaseTimerFired()
        }
        t.resume()
        timer = t

        os_log("JitterBuffer: started (mode=%{public}@, depth=%dms)",
               log: Self.log, type: .info,
               config.transportMode == .tcp ? "TCP" : "UDP",
               config.bufferDepthMs)
    }

    /// Cancels the release timer. Must be called on `jitterQueue`.
    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - Release Logic

    /// Called on each timer tick. Decides whether to release the next frame.
    /// Must be called on `jitterQueue`.
    private func releaseTimerFired() {
        let now = ProcessInfo.processInfo.systemUptime

        // Acquire lock, decide what to do, release lock, then call back outside lock.
        var healthEvent: StreamHealthEvent?
        let frameToRelease: AccessUnit? = withLock {
            guard !buffer.isEmpty else { return nil }

            // Buffering period: hold frames until bufferDepthMs has elapsed
            // since the first enqueue after underrun/start. (Req 1.9)
            if isBuffering {
                guard let startTime = bufferingStartTime else { return nil }
                let elapsed = now - startTime
                let requiredMs = Double(effectiveDepthMs) / 1000.0
                if elapsed < requiredMs {
                    return nil
                }
                // Buffering period complete — begin releasing.
                isBuffering = false

                // Recovery from underrun: emit .recovery with stall duration. (Req 15.1, 15.2)
                if let stallStart = stallStartTime {
                    let stallDurationMs = (now - stallStart) * 1000.0
                    healthEvent = .recovery(stallDurationMs: stallDurationMs)
                    stallStartTime = nil
                }

                os_log("JitterBuffer: buffering complete (%.1fms elapsed), releasing",
                       log: Self.log, type: .info, elapsed * 1000.0)
            }

            guard !buffer.isEmpty else { return nil }

            let frame = buffer.first!

            // Establish base timestamps on the first frame.
            if baseRtpTimestamp == nil {
                baseRtpTimestamp = frame.rtpTimestamp
                baseWallClock = now
                lastReleasedTimestamp = frame.rtpTimestamp
                buffer.removeFirst()
                _totalFramesReleased += 1
                return frame
            }

            // Compute the RTP-timestamp-derived release interval and update EMA.
            // (Req 1.4, 1.5, 2.1, 2.2, 2.5)
            let rawDelta = Int32(bitPattern: frame.rtpTimestamp &- lastReleasedTimestamp!)
            if rawDelta > 0 {
                let rawInterval = Double(rawDelta) / 90000.0
                _ = applyEMA(rawInterval: rawInterval)
            }

            // Check if enough wall-clock time has passed since the base to release this frame.
            let targetWallClock = baseWallClock! + computePlayout(for: frame)
            if now < targetWallClock - 0.0005 {
                // Not yet time to release this frame.
                return nil
            }

            buffer.removeFirst()
            lastReleasedTimestamp = frame.rtpTimestamp
            _totalFramesReleased += 1

            // Update output FPS estimate.
            updateOutputFps(now: now)

            // If buffer is now empty, enter buffering state for next batch. (Req 1.9)
            // Also record stall start time and emit .stall event. (Req 15.1, 15.2)
            if buffer.isEmpty {
                isBuffering = true
                bufferingStartTime = nil
                stallStartTime = now
                // Only emit stall if we don't already have a recovery event queued
                if healthEvent == nil {
                    healthEvent = .stall(timestamp: now)
                }
            }

            return frame
        }

        // Invoke callbacks outside the lock to avoid deadlock.
        if let event = healthEvent {
            onStreamHealth?(event)
        }
        if let frame = frameToRelease {
            onReleaseFrame?(frame)
        }
    }

    /// Computes the playout offset (in seconds) for a frame relative to `baseWallClock`.
    /// Uses cumulative RTP timestamp delta from the base. (Req 2.1)
    private func computePlayout(for frame: AccessUnit) -> TimeInterval {
        guard let base = baseRtpTimestamp else { return 0 }
        let delta = Int32(bitPattern: frame.rtpTimestamp &- base)
        if delta <= 0 { return 0 }
        return Double(delta) / 90000.0
    }

    // MARK: - EMA Computation (Req 2.5)

    /// Applies the exponential moving average filter to the raw inter-frame interval.
    ///
    /// EMA gain is 1/16 per RFC 3550 convention:
    ///   `ema += (delta - ema) / 16`
    ///
    /// If the raw interval deviates by more than 50% from the current EMA,
    /// the EMA value is substituted for that frame's release delay.
    ///
    /// - Parameter rawInterval: The interval in seconds derived from RTP timestamp delta.
    /// - Returns: The interval to use for release timing (raw or EMA-substituted).
    private func applyEMA(rawInterval: Double) -> Double {
        guard rawInterval > 0 else { return 0 }

        guard var ema = emaInterval else {
            // First inter-frame delta — seed the EMA.
            emaInterval = rawInterval
            return rawInterval
        }

        // Update EMA: ema += (delta - ema) / 16
        ema += (rawInterval - ema) / 16.0
        emaInterval = ema

        // Outlier substitution: if deviation > 50%, use EMA instead. (Req 2.5)
        let deviation = abs(rawInterval - ema) / ema
        if deviation > 0.5 {
            return ema
        }
        return rawInterval
    }

    // MARK: - Output FPS Tracking

    /// Timestamp of the last released frame (wall-clock) for FPS computation.
    private var lastReleaseWallClock: TimeInterval?
    /// Sliding window of recent release intervals for FPS averaging.
    private var recentReleaseIntervals: [Double] = []
    private static let fpsWindowSize = 30

    /// Updates the output FPS estimate based on recent release intervals.
    private func updateOutputFps(now: TimeInterval) {
        if let lastRelease = lastReleaseWallClock {
            let interval = now - lastRelease
            if interval > 0 {
                recentReleaseIntervals.append(interval)
                if recentReleaseIntervals.count > Self.fpsWindowSize {
                    recentReleaseIntervals.removeFirst()
                }
                let avgInterval = recentReleaseIntervals.reduce(0, +) / Double(recentReleaseIntervals.count)
                _stats.currentOutputFps = avgInterval > 0 ? 1.0 / avgInterval : 0
            }
        }
        lastReleaseWallClock = now
    }

    // MARK: - Testing Support

    /// Exposes the internal buffer count for testing. Thread-safe.
    var bufferCount: Int {
        withLock { buffer.count }
    }

    /// Exposes the current EMA interval for testing. Thread-safe.
    var currentEMAInterval: Double? {
        withLock { emaInterval }
    }

    /// Exposes the buffering state for testing. Thread-safe.
    var isInBufferingState: Bool {
        withLock { isBuffering }
    }

    /// Exposes the current adaptive depth for testing. Thread-safe. (Req 13.4)
    var currentAdaptiveDepth: Int {
        withLock { adaptiveDepthMs }
    }

    /// Synchronously releases the next frame if available, bypassing the timer.
    /// Used for testing to verify ordering and data integrity without real-time waits.
    /// Returns the released frame, or nil if the buffer is empty.
    @discardableResult
    func releaseNextForTesting() -> AccessUnit? {
        var healthEvent: StreamHealthEvent?
        let frame: AccessUnit? = withLock {
            guard !buffer.isEmpty else { return nil }

            let frame = buffer.removeFirst()

            // Establish base timestamps on the first frame.
            if baseRtpTimestamp == nil {
                baseRtpTimestamp = frame.rtpTimestamp
                baseWallClock = ProcessInfo.processInfo.systemUptime
            }

            // Recovery from underrun: emit .recovery with stall duration. (Req 15.1, 15.2)
            if isBuffering, let stallStart = stallStartTime {
                let now = ProcessInfo.processInfo.systemUptime
                let stallDurationMs = (now - stallStart) * 1000.0
                healthEvent = .recovery(stallDurationMs: stallDurationMs)
                stallStartTime = nil
            }
            isBuffering = false

            // Update EMA if we have a previous timestamp.
            if let prev = lastReleasedTimestamp {
                let rawDelta = Int32(bitPattern: frame.rtpTimestamp &- prev)
                if rawDelta > 0 {
                    let rawInterval = Double(rawDelta) / 90000.0
                    _ = applyEMA(rawInterval: rawInterval)
                }
            }

            lastReleasedTimestamp = frame.rtpTimestamp
            _totalFramesReleased += 1

            if buffer.isEmpty {
                isBuffering = true
                bufferingStartTime = nil
                let now = ProcessInfo.processInfo.systemUptime
                stallStartTime = now
                // Only emit stall if we don't already have a recovery event queued
                if healthEvent == nil {
                    healthEvent = .stall(timestamp: now)
                }
            }

            return frame
        }

        // Invoke callbacks outside the lock to avoid deadlock.
        if let event = healthEvent {
            onStreamHealth?(event)
        }
        if let frame = frame {
            onReleaseFrame?(frame)
        }
        return frame
    }

    /// Computes the RTP timestamp to wall-clock interval for two timestamps.
    /// Public static method for property testing. (Property 1)
    ///
    /// Uses wraparound-safe arithmetic: `Double(Int32(bitPattern: T2 &- T1)) / 90000.0`
    static func rtpIntervalSeconds(from t1: UInt32, to t2: UInt32) -> Double {
        return Double(Int32(bitPattern: t2 &- t1)) / 90000.0
    }
}
