import Flutter
import Foundation
import os.log

/// Manages all active RTSP streaming sessions.
///
/// Thread safety: all mutations to `sessions` and `nextStreamId` are
/// serialised on `queue`. All `FlutterResult` callbacks are dispatched
/// back to the main thread.
class RtspStreamManager {

    // MARK: - Constants

    private static let maxStreams = 8

    // MARK: - Dependencies

    private let textureRegistry: FlutterTextureRegistry
    private let binaryMessenger: FlutterBinaryMessenger

    // MARK: - State

    /// Serial queue protecting `sessions` and `nextStreamId`.
    private let queue = DispatchQueue(label: "com.pandawatch.flutter_rtsps_plugin.manager")

    private var sessions: [Int: RtspStreamSession] = [:]
    private var nextStreamId: Int = 1
    private var debugLogging: Bool = false

    // MARK: - Init

    init(textureRegistry: FlutterTextureRegistry, binaryMessenger: FlutterBinaryMessenger) {
        self.textureRegistry = textureRegistry
        self.binaryMessenger = binaryMessenger
    }

    // MARK: - Public API

    func startStream(url: String, username: String, password: String, result: @escaping FlutterResult) {
        queue.async { [weak self] in
            guard let self else { return }

            if self.sessions.count >= RtspStreamManager.maxStreams {
                self.log("startStream rejected: tooManyStreams (count=\(self.sessions.count))")
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "tooManyStreams",
                        message: "Maximum of \(RtspStreamManager.maxStreams) concurrent streams reached",
                        details: nil
                    ))
                }
                return
            }

            let streamId = self.nextStreamId
            self.nextStreamId += 1

            let session = RtspStreamSession(
                streamId: streamId,
                url: url,
                username: username,
                password: password,
                textureRegistry: self.textureRegistry,
                binaryMessenger: self.binaryMessenger
            )
            self.sessions[streamId] = session
            self.log("startStream: created session streamId=\(streamId)")

            // Store the Task so stopStream can cancel an in-flight start (Defect 1.7)
            let task: Task<Int, Error> = Task {
                do {
                    let textureId = try await session.start()
                    DispatchQueue.main.async {
                        result(["streamId": streamId, "textureId": textureId])
                    }
                    return textureId
                } catch {
                    self.queue.async {
                        self.sessions.removeValue(forKey: streamId)
                    }
                    let flutterError = self.mapError(error)
                    DispatchQueue.main.async {
                        result(flutterError)
                    }
                    throw error
                }
            }
            session.startTask = task
        }
    }

    func stopStream(streamId: Int, result: @escaping FlutterResult) {
        queue.async { [weak self] in
            guard let self else { return }

            guard let session = self.sessions.removeValue(forKey: streamId) else {
                // Idempotent — unknown streamId is not an error
                self.log("stopStream: streamId=\(streamId) not found (idempotent)")
                DispatchQueue.main.async { result(nil) }
                return
            }

            self.log("stopStream: stopping streamId=\(streamId)")
            // Cancel any in-flight start() Task before stopping (Defect 1.7)
            session.startTask?.cancel()
            session.startTask = nil
            Task {
                await session.stop()
                DispatchQueue.main.async { result(nil) }
            }
        }
    }

    func captureSnapshot(
        url: String,
        username: String,
        password: String,
        timeoutSeconds: Int,
        result: @escaping FlutterResult
    ) {
        Task {
            do {
                let snapshot = SnapshotCapture()
                let jpegData = try await snapshot.capture(
                    url: url,
                    username: username,
                    password: password,
                    timeoutSeconds: timeoutSeconds
                )
                let typedData = FlutterStandardTypedData(bytes: jpegData)
                DispatchQueue.main.async {
                    result(typedData)
                }
            } catch {
                let flutterError = self.mapError(error)
                DispatchQueue.main.async {
                    result(flutterError)
                }
            }
        }
    }

    func captureFrameFromStream(streamId: Int, result: @escaping FlutterResult) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let session = self.sessions[streamId] else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "connectionFailed", message: "No active stream for streamId \(streamId)", details: nil))
                }
                return
            }
            if let jpegData = session.captureFrame() {
                let typedData = FlutterStandardTypedData(bytes: jpegData)
                DispatchQueue.main.async { result(typedData) }
            } else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "connectionFailed", message: "No frame available yet", details: nil))
                }
            }
        }
    }

    func dispose(result: @escaping FlutterResult) {
        queue.async { [weak self] in
            guard let self else { return }
            self.log("dispose: stopping all \(self.sessions.count) sessions")
            let allSessions = Array(self.sessions.values)
            self.sessions.removeAll()

            Task {
                await withTaskGroup(of: Void.self) { group in
                    for session in allSessions {
                        group.addTask { await session.stop() }
                    }
                }
                DispatchQueue.main.async { result(nil) }
            }
        }
    }

    func setDebugLogging(enabled: Bool) {
        queue.async { [weak self] in
            self?.debugLogging = enabled
        }
    }

    /// Stops all sessions without a FlutterResult callback.
    /// Called from `detachFromEngine`.
    func disposeAll() {
        queue.async { [weak self] in
            guard let self else { return }
            let allSessions = Array(self.sessions.values)
            self.sessions.removeAll()
            Task {
                await withTaskGroup(of: Void.self) { group in
                    for session in allSessions {
                        group.addTask { await session.stop() }
                    }
                }
            }
        }
    }

    // MARK: - Private helpers

    private static let logger = OSLog(
        subsystem: "com.pandawatch.flutter_rtsps_plugin",
        category: "RtspStreamManager"
    )

    private func log(_ message: String) {
        guard debugLogging else { return }
        os_log("%{public}@", log: RtspStreamManager.logger, type: .debug, message)
    }

    private func mapError(_ error: Error) -> FlutterError {
        guard let rtspError = error as? RtspError else {
            return FlutterError(code: "connectionFailed", message: error.localizedDescription, details: nil)
        }
        switch rtspError {
        case .connectionFailed(let msg):
            return FlutterError(code: "connectionFailed", message: msg, details: nil)
        case .authenticationFailed:
            return FlutterError(code: "authenticationFailed", message: "Authentication failed", details: nil)
        case .timeout:
            return FlutterError(code: "timeout", message: "Request timed out", details: nil)
        case .noVideoTrack:
            return FlutterError(code: "noVideoTrack", message: "No video track found in SDP", details: nil)
        case .decoderError:
            return FlutterError(code: "decoderError", message: "H.264 decoder error", details: nil)
        case .tooManyStreams:
            return FlutterError(code: "tooManyStreams", message: "Too many concurrent streams", details: nil)
        }
    }
}
