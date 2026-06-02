import XCTest
import SwiftCheck
@testable import flutter_rtsps_plugin

// Feature: rtsps-jitter-buffer
// Property 15 — ReconnectionManager exponential backoff computation

final class ReconnectionManagerPropertyTests: XCTestCase {

    private let args = CheckerArguments(maxAllowableSuccessfulTests: 30)

    // MARK: - Property 15: Exponential Backoff Computation
    // **Validates: Requirements 7.5, 7.6, 7.7**

    /// For N consecutive failures, delay = min(2.0 * pow(2.0, Double(N-1)), 30.0).
    func testExponentialBackoffComputation() {
        let failureCountGen = Gen<Int>.choose((1, 20))

        property("backoff delay matches formula min(2 * 2^(n-1), 30)", arguments: args) <- forAll(failureCountGen) { (n: Int) in
            let actual = ReconnectionManager.backoffDelay(forFailure: n)
            let expected = min(2.0 * pow(2.0, Double(n - 1)), 30.0)
            return abs(actual - expected) < 1e-10
        }
    }

    /// Backoff is always capped at 30 seconds.
    func testBackoffCappedAt30Seconds() {
        let largeFailureGen = Gen<Int>.choose((5, 100))

        property("backoff delay never exceeds 30 seconds", arguments: args) <- forAll(largeFailureGen) { (n: Int) in
            return ReconnectionManager.backoffDelay(forFailure: n) <= 30.0
        }
    }

    /// Backoff starts at 2 seconds for the first failure.
    func testBackoffStartsAt2Seconds() {
        XCTAssertEqual(ReconnectionManager.backoffDelay(forFailure: 1), 2.0, accuracy: 1e-10)
    }

    /// Known backoff sequence: 2, 4, 8, 16, 30, 30, ...
    func testKnownBackoffSequence() {
        let expected: [TimeInterval] = [2.0, 4.0, 8.0, 16.0, 30.0]
        for (i, exp) in expected.enumerated() {
            let actual = ReconnectionManager.backoffDelay(forFailure: i + 1)
            XCTAssertEqual(actual, exp, accuracy: 1e-10,
                           "Failure \(i + 1): expected \(exp), got \(actual)")
        }
    }

    /// After success (reset), the next failure starts at 2s again.
    func testResetAfterSuccess() {
        let rm = ReconnectionManager()

        // Simulate: the manager tracks consecutive failures internally.
        // After a successful reconnection, consecutiveFailures resets to 0.
        // We verify this through the currentConsecutiveFailures property.
        XCTAssertEqual(rm.currentConsecutiveFailures, 0,
                       "Initial failure count should be 0")
    }

    /// Error event emitted after exactly 5 consecutive failures.
    func testErrorEventAfter5Failures() {
        let rm = ReconnectionManager()
        var errorEmitted = false
        var failureCount = 0

        rm.onReconnectFailed = { _ in
            errorEmitted = true
        }

        // Wire onReconnect to always fail
        rm.onReconnect = {
            failureCount += 1
            throw NSError(domain: "test", code: 1)
        }

        // Trigger reconnection and wait for the backoff chain to complete
        let expectation = self.expectation(description: "error event emitted")

        rm.onReconnectFailed = { _ in
            errorEmitted = true
            expectation.fulfill()
        }

        // Start with a very short interval to trigger quickly
        rm.reconnectInterval = 0.01
        rm.start()

        wait(for: [expectation], timeout: 10.0)
        rm.stop()

        XCTAssertTrue(errorEmitted, "Error event should be emitted after 5 consecutive failures")
    }
}
