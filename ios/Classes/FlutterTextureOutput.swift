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
    /// True when a `textureFrameAvailable` call has been dispatched to the main
    /// thread but hasn't executed yet. Prevents a bursty decoder (e.g. catching
    /// up after a stall) from flooding the main-thread dispatch queue with
    /// redundant notifications, which would starve other texture instances
    /// sharing the same main-thread run loop.
    private var pendingTextureNotification = false
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
    ///
    /// Uses a coalescing flag (`pendingTextureNotification`) so that if multiple
    /// frames arrive before the main thread processes the notification, only one
    /// `textureFrameAvailable` call is enqueued. This prevents a bursty stream
    /// (catching up after a jitter/stall) from flooding the main-thread dispatch
    /// queue and delaying texture notifications for other concurrent streams.
    ///
    /// The incoming CVPixelBuffer is stored as a strong reference so that
    /// VideoToolbox cannot recycle the backing IOSurface while Flutter's
    /// Metal renderer is still accessing the texture. Swift's ARC retains
    /// the buffer automatically when assigned to `latestPixelBuffer` and
    /// releases the previous buffer on reassignment (PANDA-WATCH-24).
    func onNewFrame(_ pixelBuffer: CVPixelBuffer) {
        let shouldNotify = withLock {
            // ARC releases the previous buffer when we replace the reference.
            latestPixelBuffer = pixelBuffer
            if pendingTextureNotification {
                // A notification is already queued — it will pick up this newer buffer.
                return false
            }
            pendingTextureNotification = true
            return true
        }

        guard shouldNotify else { return }

        let id = textureId
        let registry = textureRegistry
        if Thread.isMainThread {
            registry?.textureFrameAvailable(id)
            withLock { pendingTextureNotification = false }
        } else {
            DispatchQueue.main.async { [weak self] in
                registry?.textureFrameAvailable(id)
                self?.withLock { self?.pendingTextureNotification = false }
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
        //    Release the retained pixel buffer to balance the CVPixelBufferRetain
        //    in onNewFrame (PANDA-WATCH-24).
        let (registry, id) = withLock { () -> (FlutterTextureRegistry?, Int64) in
            let reg = textureRegistry
            let tid = textureId
            // ARC releases the buffer when we nil the reference.
            latestPixelBuffer = nil
            pendingTextureNotification = false
            textureRegistry = nil
            return (reg, tid)
        }

        // 2. Outside lock: unregister. If this triggers a final copyPixelBuffer,
        //    the buffer is already nil so it returns nil — no deadlock.
        registry?.unregisterTexture(id)
        os_log("FlutterTextureOutput: texture %lld unregistered", log: log, type: .info, id)
    }
}
