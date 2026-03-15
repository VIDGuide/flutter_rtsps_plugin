/// Error codes for RTSP stream failures.
enum RtspErrorCode {
  connectionFailed,
  authenticationFailed,
  timeout,
  noVideoTrack,
  decoderError,
  tooManyStreams,
}

/// Exception thrown by [RtspStreamController] methods on failure.
class RtspException implements Exception {
  const RtspException({required this.code, required this.message});

  final RtspErrorCode code;
  final String message;

  @override
  String toString() => 'RtspException(${code.name}): $message';
}
