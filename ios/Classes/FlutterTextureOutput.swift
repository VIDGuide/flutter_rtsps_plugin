import Flutter
import Foundation
import os.log

// MARK: - FlutterTextureOutput

/// Delivers decoded `CVPixelBuffer` frames to Flutter via `FlutterTextureRegistry`.
///
/// Usage:
/// 1. Create with `init(textureRegistry:)` — registers self and stores `textureId`.
/// 2. Pass `onNewFrame(_:)` as the `onPixelBuffer` callback to `H264Decoder`.
/// 3. Call `stop()` when the stream ends to unregister the texture.
///
/// Thread safety: `latestPixelBuffer` is protected by `os_unfair_lock`.
/// `copyPixelBuffer()` may be called from Flutter's render thread;
/// `onNewFrame(_:)` is called from the VideoToolbox decoder queue.
/// `os_unfair_lock` is used instead of `NSLock` for lower overhead on the
/// render-thread hot path (Req 2.34).
///
/// Requirements: 5.1, 5.2, 5.4, 5.5, 5.6
final class FlutterTextureOutput: NSObject, FlutterTexture {

    // MARK: - Public

    /// The texture ID assigned by Flutter's `TextureRegistry`. (Req 5.1, 5.3)
    private(set) var textureId: Int64 = 0

    // MARK: - Private

    private weak var textureRegistry: FlutterTextureRegistry?
    private var latestPixelBuffer: CVPixelBuffer?
    private var _lock = os_unfair_lock()
    private let log = OSLog(subsystem: "com.pandawatch.flutter_rtsps_plugin",
                            category: "FlutterTextureOutput")

    /// Executes `body` while holding `os_unfair_lock`. Non-reentrant and faster
    /// than `NSLock` for the short critical sections on the render thread.
    private func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return body()
    }

    /// Shared CIContext — expensive to create, reused across all captureJpeg calls.
    private let ciContext = CIContext()

    // MARK: - Init

    /// Registers this texture with the Flutter `TextureRegistry` and stores the
    /// returned `textureId`. (Req 5.1)
    ///
    /// - Parameter textureRegistry: The Flutter texture registry obtained from
    ///   the plugin registrar. Stored weakly to avoid retain cycles.
    init(textureRegistry: FlutterTextureRegistry) {
        self.textureRegistry = textureRegistry
        super.init()
        // Register self after super.init() so `self` is fully initialised.
        self.textureId = textureRegistry.register(self)
        os_log("FlutterTextureOutput: registered texture %lld", log: log, type: .info, textureId)
    }

    // MARK: - FlutterTexture

    /// Returns the most recently decoded `CVPixelBuffer` to Flutter's render thread.
    /// Uses a lock-protected swap so the render thread always gets the latest frame.
    /// (Req 5.2)
    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        let buffer = withLock { latestPixelBuffer }
        guard let buffer else { return nil }
        return Unmanaged.passRetained(buffer)
    }

    // MARK: - New Frame

    /// Called by `H264Decoder`'s `onPixelBuffer` callback when a decoded frame
    /// is ready. Stores the buffer and notifies Flutter on the main thread. (Req 5.2, 5.5)
    func onNewFrame(_ pixelBuffer: CVPixelBuffer) {
        withLock { latestPixelBuffer = pixelBuffer }

        // textureFrameAvailable MUST be called on the main thread (Req 5.5)
        let id = textureId
        let registry = textureRegistry
        if Thread.isMainThread {
            registry?.textureFrameAvailable(id)
        } else {
            DispatchQueue.main.async {
                registry?.textureFrameAvailable(id)
            }
        }
    }

    // MARK: - Snapshot

    /// Encodes the most recently decoded frame as JPEG data.
    ///
    /// Returns `nil` if no frame has been received yet.
    func captureJpeg(compressionQuality: CGFloat = 0.85) -> Data? {
        let buffer = withLock { latestPixelBuffer }
        guard let buffer else { return nil }

        let ciImage = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        let uiImage = UIImage(cgImage: cgImage)
        return uiImage.jpegData(compressionQuality: compressionQuality)
    }

    // MARK: - Stop

    /// Unregisters the texture from Flutter's `TextureRegistry` to release GPU
    /// memory. (Req 5.4)
    ///
    /// Lock ordering: acquire lock → nil buffer & registry → release lock →
    /// call `unregisterTexture`. This ensures that if `unregisterTexture`
    /// triggers a final `copyPixelBuffer` call, it finds a nil buffer and
    /// returns nil without deadlocking. (Req 2.19)
    func stop() {
        // 1. Under lock: capture registry ref and textureId, then nil out state
        //    so any concurrent copyPixelBuffer returns nil immediately.
        let (registry, id) = withLock { () -> (FlutterTextureRegistry?, Int64) in
            let reg = textureRegistry
            let tid = textureId
            latestPixelBuffer = nil
            textureRegistry = nil
            return (reg, tid)
        }

        // 2. Outside lock: unregister. If this triggers a final copyPixelBuffer,
        //    the buffer is already nil so it returns nil — no deadlock.
        registry?.unregisterTexture(id)
        os_log("FlutterTextureOutput: texture %lld unregistered", log: log, type: .info, id)
    }
}
