import Flutter
import UIKit

public class FlutterRtspsPlugin: NSObject, FlutterPlugin {

    private var streamManager: RtspStreamManager?
    private var registrar: FlutterPluginRegistrar?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "flutter_rtsps_plugin/methods",
            binaryMessenger: registrar.messenger()
        )
        let instance = FlutterRtspsPlugin()
        instance.registrar = registrar
        instance.streamManager = RtspStreamManager(
            textureRegistry: registrar.textures(),
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(instance, channel: channel)
        registrar.addApplicationDelegate(instance)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let manager = streamManager else {
            result(FlutterError(code: "connectionFailed", message: "Plugin not initialized", details: nil))
            return
        }

        let args = call.arguments as? [String: Any]

        switch call.method {
        case "startStream":
            guard
                let url = args?["url"] as? String,
                let username = args?["username"] as? String,
                let password = args?["password"] as? String
            else {
                result(FlutterError(code: "connectionFailed", message: "Missing required arguments", details: nil))
                return
            }
            manager.startStream(url: url, username: username, password: password, result: result)

        case "stopStream":
            guard let streamId = args?["streamId"] as? Int else {
                result(FlutterError(code: "connectionFailed", message: "Missing streamId", details: nil))
                return
            }
            manager.stopStream(streamId: streamId, result: result)

        case "captureFrameFromStream":
            guard let streamId = args?["streamId"] as? Int else {
                result(FlutterError(code: "connectionFailed", message: "Missing streamId", details: nil))
                return
            }
            manager.captureFrameFromStream(streamId: streamId, result: result)

        case "captureSnapshot":
            guard
                let url = args?["url"] as? String,
                let username = args?["username"] as? String,
                let password = args?["password"] as? String
            else {
                result(FlutterError(code: "connectionFailed", message: "Missing required arguments", details: nil))
                return
            }
            let timeoutSeconds = args?["timeoutSeconds"] as? Int ?? 10
            manager.captureSnapshot(url: url, username: username, password: password, timeoutSeconds: timeoutSeconds, result: result)

        case "dispose":
            manager.dispose(result: result)

        case "setDebugLogging":
            let enabled = args?["enabled"] as? Bool ?? false
            manager.setDebugLogging(enabled: enabled)
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // Called when the Flutter engine is detached/destroyed
    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        streamManager?.disposeAll()
        streamManager = nil
    }
}
