import 'rtsp_exception.dart';

/// Events emitted by [RtspStreamController.streamEvents].
sealed class RtspStreamEvent {
  const RtspStreamEvent();
}

/// The stream has started delivering decoded video frames.
final class RtspPlayingEvent extends RtspStreamEvent {
  const RtspPlayingEvent();
}

/// An error occurred on the stream.
final class RtspErrorEvent extends RtspStreamEvent {
  const RtspErrorEvent(this.exception);

  final RtspException exception;
}

/// The stream ended cleanly.
final class RtspStoppedEvent extends RtspStreamEvent {
  const RtspStoppedEvent();
}

/// A video frame was decoded. Emitted for every frame after the first.
final class RtspFrameEvent extends RtspStreamEvent {
  const RtspFrameEvent({required this.timestampMs});
  /// Milliseconds since epoch when the frame was decoded.
  final int timestampMs;
}
