import Foundation
import os.log

// MARK: - ReconnectionManager

/// Periodic reconnection manager to preempt the Live555 hang bug during
/// long print jobs. Fires every `reconnectInterval` seconds and coordinates
/// a full pipeline swap via the `onReconnect` callback.
///
/// On failure, uses exponential backoff: 2s → 4s → 8s → 16s → 30s cap.
/// After 5 consecutive failures, emits an error event and keeps the old
/// session if still active.
///
/// Requirements: 7.1, 7.5, 7.6, 7.7, 7.8
final class ReconnectionManager {

    // MARK: - Configuration

    /// Interval between reconnection cycles (default 5 minutes). (Req 7.1)
    var reconnectInterval: TimeInterval = 300

    // MARK: - Callbacks

    /// Called to request a new pipeline from the session.
    var onReconnect: (() async throws -> Void)?

    /// Called when reconnection fails after 5 consecutive attempts. (Req 7.6)
    var onReconnectFailed: ((Error) -> Void)?

    // MARK: - Private state

    private var timer: DispatchSourceTimer?
    private let reconnectQueue = DispatchQueue(
        label: "com.pandawatch.flutter_rtsps_plugin.reconnect",
        qos: .utility
    )

    /// Number of consecutive reconnection failures.
    private var consecutiveFailures: Int = 0

    /// Maximum consecutive failures before emitting error event.
    private static let maxConsecutiveFailures = 5

    /// Base backoff delay in seconds.
    private static let baseBackoff: TimeInterval = 2.0

    /// Maximum backoff delay in seconds.
    private static let maxBackoff: TimeInterval = 30.0

    private let log = OSLog(subsystem: "com.pandawatch.flutter_rtsps_plugin", category: "ReconnectionManager")

    // MARK: - Computed (for testing)

    /// Computes the backoff delay for a given failure count (1-indexed).
    /// Formula: min(2.0 * pow(2.0, Double(n - 1)), 30.0)
    static func backoffDelay(forFailure n: Int) -> TimeInterval {
        guard n >= 1 else { return baseBackoff }
        return min(baseBackoff * pow(2.0, Double(n - 1)), maxBackoff)
    }

    /// Current consecutive failure count (exposed for testing).
    var currentConsecutiveFailures: Int { consecutiveFailures }

    // MARK: - Lifecycle

    /// Start the periodic reconnection timer. (Req 7.1)
    func start() {
        stop() // Cancel any existing timer

        let t = DispatchSource.makeTimerSource(queue: reconnectQueue)
        t.schedule(deadline: .now() + reconnectInterval, repeating: reconnectInterval)
        t.setEventHandler { [weak self] in
            self?.performReconnection()
        }
        t.resume()
        timer = t
        os_log("ReconnectionManager: started (interval=%.0fs)", log: log, type: .info, reconnectInterval)
    }

    /// Stop the timer and cancel any pending reconnection. (Req 7.8)
    func stop() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - Reconnection Logic

    private func performReconnection() {
        guard let onReconnect = onReconnect else { return }

        Task {
            do {
                try await onReconnect()
                // Success — reset backoff counter (Req 7.7)
                self.reconnectQueue.async {
                    self.consecutiveFailures = 0
                    os_log("ReconnectionManager: reconnection succeeded, backoff reset",
                           log: self.log, type: .info)
                }
            } catch {
                self.reconnectQueue.async {
                    self.handleFailure(error)
                }
            }
        }
    }

    private func handleFailure(_ error: Error) {
        consecutiveFailures += 1
        os_log("ReconnectionManager: reconnection failed (%d/%d): %{public}@",
               log: log, type: .error,
               consecutiveFailures, Self.maxConsecutiveFailures,
               error.localizedDescription)

        if consecutiveFailures >= Self.maxConsecutiveFailures {
            // Emit error event after 5 consecutive failures (Req 7.6)
            os_log("ReconnectionManager: %d consecutive failures, emitting error event",
                   log: log, type: .fault, consecutiveFailures)
            onReconnectFailed?(error)
            return
        }

        // Retry with exponential backoff (Req 7.5)
        let delay = Self.backoffDelay(forFailure: consecutiveFailures)
        os_log("ReconnectionManager: retrying in %.1fs (attempt %d)",
               log: log, type: .info, delay, consecutiveFailures)

        reconnectQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.performReconnection()
        }
    }
}
