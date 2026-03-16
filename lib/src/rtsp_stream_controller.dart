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
  Stream<RtspStreamEvent> streamEvents(int streamId) {
    final eventChannel = EventChannel(
      'flutter_rtsps_plugin/events/$streamId',
    );
    return eventChannel.receiveBroadcastStream().map(_mapEvent);
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

  RtspStreamEvent _mapEvent(dynamic raw) {
    if (raw is! Map) {
      return const RtspStoppedEvent();
    }
    final type = raw['type'] as String?;
    switch (type) {
      case 'playing':
        return const RtspPlayingEvent();
      case 'stopped':
        return const RtspStoppedEvent();
      case 'error':
        final code = _parseErrorCode(raw['code'] as String?);
        final message = (raw['message'] as String?) ?? 'Unknown error';
        return RtspErrorEvent(RtspException(code: code, message: message));
      case 'frame':
        final ts = (raw['ts'] as num?)?.toInt() ?? 0;
        return RtspFrameEvent(timestampMs: ts);
      default:
        return const RtspStoppedEvent();
    }
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
