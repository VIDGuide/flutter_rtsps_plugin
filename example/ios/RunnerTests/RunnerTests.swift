import Flutter
import UIKit
import XCTest

@testable import flutter_rtsps_plugin

class RunnerTests: XCTestCase {

  /// Verifies that calling a method on an unregistered plugin instance
  /// returns a FlutterError (plugin not initialized).
  func testUninitializedPluginReturnsError() {
    let plugin = FlutterRtspsPlugin()

    let call = FlutterMethodCall(methodName: "startStream", arguments: [
      "url": "rtsps://example.com",
      "username": "user",
      "password": "pass"
    ])

    let resultExpectation = expectation(description: "result block must be called.")
    plugin.handle(call) { result in
      guard let error = result as? FlutterError else {
        XCTFail("Expected FlutterError, got \(String(describing: result))")
        resultExpectation.fulfill()
        return
      }
      XCTAssertEqual(error.code, "connectionFailed")
      XCTAssertEqual(error.message, "Plugin not initialized")
      resultExpectation.fulfill()
    }
    waitForExpectations(timeout: 1)
  }

}
