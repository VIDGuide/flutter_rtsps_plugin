import XCTest
import SwiftCheck
@testable import flutter_rtsps_plugin

// Feature: rtsps-jitter-buffer, Property 14: Buffer Depth Clamping

/// **Validates: Requirements 12.3**
///
/// Property 14: Buffer Depth Clamping
/// For any integer value, JitterBufferConfig clamps bufferDepthMs to [50, 1000].
/// Values below 50 become 50, above 1000 become 1000, within range preserved.
final class JitterBufferConfigPropertyTests: XCTestCase {

    private let args = CheckerArguments(maxAllowableSuccessfulTests: 30)

    // MARK: - Property 14: Buffer Depth Clamping

    /// For any integer value provided as bufferDepthMs, the resulting config
    /// clamps to [50, 1000] for TCP transport mode.
    func testBufferDepthClampingTCP() {
        property("Buffer depth is clamped to [50, 1000] for TCP", arguments: args) <- forAll { (raw: Int) in
            let config = JitterBufferConfig(bufferDepthMs: raw, transportMode: .tcp)
            return config.bufferDepthMs >= 50
                && config.bufferDepthMs <= 1000
        }
    }

    /// For any integer value provided as bufferDepthMs, the resulting config
    /// clamps to [50, 1000] for UDP transport mode.
    func testBufferDepthClampingUDP() {
        property("Buffer depth is clamped to [50, 1000] for UDP", arguments: args) <- forAll { (raw: Int) in
            let config = JitterBufferConfig(bufferDepthMs: raw, transportMode: .udp)
            return config.bufferDepthMs >= 50
                && config.bufferDepthMs <= 1000
        }
    }

    /// Values below 50 become exactly 50.
    func testBelowMinimumBecomesFloor() {
        property("Values below 50 are clamped to 50", arguments: args) <- forAll(Gen<Int>.choose((Int.min, 49))) { (raw: Int) in
            let tcpConfig = JitterBufferConfig(bufferDepthMs: raw, transportMode: .tcp)
            let udpConfig = JitterBufferConfig(bufferDepthMs: raw, transportMode: .udp)
            return tcpConfig.bufferDepthMs == 50
                && udpConfig.bufferDepthMs == 50
        }
    }

    /// Values above 1000 become exactly 1000.
    func testAboveMaximumBecomesCeiling() {
        property("Values above 1000 are clamped to 1000", arguments: args) <- forAll(Gen<Int>.choose((1001, Int.max))) { (raw: Int) in
            let tcpConfig = JitterBufferConfig(bufferDepthMs: raw, transportMode: .tcp)
            let udpConfig = JitterBufferConfig(bufferDepthMs: raw, transportMode: .udp)
            return tcpConfig.bufferDepthMs == 1000
                && udpConfig.bufferDepthMs == 1000
        }
    }

    /// Values within [50, 1000] are preserved exactly.
    func testWithinRangePreserved() {
        property("Values in [50, 1000] are preserved", arguments: args) <- forAll(Gen<Int>.choose((50, 1000))) { (raw: Int) in
            let tcpConfig = JitterBufferConfig(bufferDepthMs: raw, transportMode: .tcp)
            let udpConfig = JitterBufferConfig(bufferDepthMs: raw, transportMode: .udp)
            return tcpConfig.bufferDepthMs == raw
                && udpConfig.bufferDepthMs == raw
        }
    }

    /// Default depth (nil) produces 150 for TCP and 300 for UDP, both within range.
    func testDefaultDepthWithinRange() {
        let tcpConfig = JitterBufferConfig(transportMode: .tcp)
        let udpConfig = JitterBufferConfig(transportMode: .udp)

        XCTAssertEqual(tcpConfig.bufferDepthMs, 150)
        XCTAssertEqual(udpConfig.bufferDepthMs, 300)
        XCTAssertTrue(tcpConfig.bufferDepthMs >= 50 && tcpConfig.bufferDepthMs <= 1000)
        XCTAssertTrue(udpConfig.bufferDepthMs >= 50 && udpConfig.bufferDepthMs <= 1000)
    }
}
