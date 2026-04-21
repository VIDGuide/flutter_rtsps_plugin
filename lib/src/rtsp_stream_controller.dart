import 'dart:async';

import 'package:flutter/services.dart';

import 'rtsp_exception.dart';
import 'rtsp_stream_event.dart';

/// Controls RTSP stream sessions and snapshot capture.
///
/// All methods delegate to the native platform via [MethodChannel] /
/// [EventChannel].
class RtspStreamController {
  RtspStreamController()
      : _methodChannel =
            const MethodChannel('flutter_rtsps_plugin/methods');

  final MethodChannel _methodChannel;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Starts an RTSP stream and returns both the stream ID and Flutter texture ID.
  ///
  /// The [textureId] can be passed directly to a `Texture(textureId:)` widget.
  /// The [streamId] is used to stop the stream or subscribe to events.
  ///
  /// Throws [RtspException] on failure.
  Future<({int streamId, int textureId})> startStream(
    String url,
    String username,
    String password,
  ) async {
    try {
      final result = await _methodChannel.invokeMethod<Map>(
        'startStream',
        {'url': url, 'username': username, 'password': password},
      );
      final map = result!;
      return (
        streamId: (map['streamId'] as num).toInt(),
        textureId: (map['textureId'] as num).toInt(),
      );
    } on PlatformException catch (e) {
      throw _convertPlatformException(e);
    }
  }

  /// Stops the stream identified by [streamId].
  ///
  /// Completes without error if [streamId] is unknown (idempotent).
  Future<void> stopStream(int streamId) async {
    try {
      await _methodChannel.invokeMethod<void>(
        'stopStream',
        {'streamId': streamId},
      );
    } on PlatformException catch (e) {
      throw _convertPlatformException(e);
    }
  }

  /// Captures a JPEG frame from an already-running stream session.
  ///
  /// This grabs the most recently decoded frame from the existing session
  /// without opening a new RTSP connection. Returns `null` if no frame has
  /// been decoded yet.
  ///
  /// Throws [RtspException] if the streamId is unknown or the platform call fails.
  Future<Uint8List?> captureFrameFromStream(int streamId) async {
    try {
      final result = await _methodChannel.invokeMethod<Uint8List>(
        'captureFrameFromStream',
        {'streamId': streamId},
      );
      return result;
    } on PlatformException catch (e) {
      throw _convertPlatformException(e);
    }
  }

  /// Captures a single JPEG frame from the given RTSP URL.
  ///
  /// [timeoutSeconds] must be between 1 and 60 (inclusive).
  ///
  /// Throws [RtspException] on failure or timeout.
  Future<Uint8List> captureSnapshot(
    String url,
    String username,
    String password, {
    int timeoutSeconds = 10,
  }) async {
    try {
      final result = await _methodChannel.invokeMethod<Uint8List>(
        'captureSnapshot',
        {
          'url': url,
          'username': username,
          'password': password,
          'timeoutSeconds': timeoutSeconds,
        },
      );
      return result!;
    } on PlatformException catch (e) {
      throw _convertPlatformException(e);
    }
  }

  /// Returns a stream of [RtspStreamEvent]s for the given [streamId].
  ///
  /// Events include [RtspPlayingEvent], [RtspErrorEvent], and
  /// [RtspStoppedEvent].
  ///
  /// The returned stream gracefully handles the case where the native session
  /// has already been torn down when Dart cancels the subscription. This
  /// prevents [MissingPluginException] crashes during MQTT reconnection
  /// (PANDA-WATCH-3M).
  Stream<RtspStreamEvent> streamEvents(int streamId) {
    final eventChannel = EventChannel(
      'flutter_rtsps_plugin/events/$streamId',
    );
    // Wrap the broadcast stream so that MissingPluginException during cancel
    // (native session already torn down) is swallowed instead of crashing.
    final controller = StreamController<RtspStreamEvent>.broadcast();
    StreamSubscription? sub;
    controller.onListen = () {
      sub = eventChannel.receiveBroadcastStream().expand(_mapEvents).listen(
        controller.add,
        onError: (e) {
          // Swallow MissingPluginException — it means the native side already
          // cleaned up the event channel (race during stop/dispose).
          if (e is MissingPluginException) return;
          controller.addError(e);
        },
        onDone: () {
          if (!controller.isClosed) controller.close();
        },
      );
    };
    controller.onCancel = () {
      try {
        sub?.cancel();
      } catch (_) {
        // Swallow errors during cancel (native handler already removed)
      }
      sub = null;
    };
    return controller.stream;
  }

  /// Stops all active streams and releases all plugin resources.
  Future<void> dispose() async {
    try {
      await _methodChannel.invokeMethod<void>('dispose');
    } on PlatformException catch (e) {
      throw _convertPlatformException(e);
    }
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Maps a raw event map from the native side to [RtspStreamEvent]s.
  ///
  /// Yields an iterable so that a single native event can produce multiple
  /// Dart events (e.g. `playing` also emits a `RtspFrameEvent` for the first
  /// frame so FpsOverlay counts it).
  Iterable<RtspStreamEvent> _mapEvents(dynamic raw) sync* {
    if (raw is! Map) {
      yield const RtspStoppedEvent();
      return;
    }
    final type = raw['type'] as String?;
    if (type == 'playing') {
      yield const RtspPlayingEvent();
      // Native side includes `ts` on the playing event so FpsOverlay counts
      // the very first frame.
      final ts = (raw['ts'] as num?)?.toInt();
      if (ts != null) yield RtspFrameEvent(timestampMs: ts);
    } else if (type == 'frame') {
      final ts = (raw['ts'] as num?)?.toInt() ?? 0;
      yield RtspFrameEvent(timestampMs: ts);
    } else if (type == 'error') {
      final code = _parseErrorCode(raw['code'] as String?);
      final message = (raw['message'] as String?) ?? 'Unknown error';
      yield RtspErrorEvent(RtspException(code: code, message: message));
    } else if (type == 'stopped') {
      yield const RtspStoppedEvent();
    }
    // Unknown event types are silently dropped — no yield means no event.
  }

  RtspException _convertPlatformException(PlatformException e) {
    final code = _parseErrorCode(e.code);
    final message = e.message ?? 'Unknown error';
    return RtspException(code: code, message: message);
  }

  RtspErrorCode _parseErrorCode(String? code) {
    switch (code) {
      case 'connectionFailed':
        return RtspErrorCode.connectionFailed;
      case 'authenticationFailed':
        return RtspErrorCode.authenticationFailed;
      case 'timeout':
        return RtspErrorCode.timeout;
      case 'noVideoTrack':
        return RtspErrorCode.noVideoTrack;
      case 'decoderError':
        return RtspErrorCode.decoderError;
      case 'tooManyStreams':
        return RtspErrorCode.tooManyStreams;
      default:
        return RtspErrorCode.connectionFailed;
    }
  }
}
