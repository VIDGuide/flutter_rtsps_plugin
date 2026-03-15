# flutter_rtsps_plugin

A Flutter plugin for iOS that streams RTSP-over-TLS (`rtsps://`) video using Apple's
`NWConnection` (Network.framework) and `VideoToolbox`. Purpose-built for Bambu Lab printer
cameras, which use self-signed TLS certificates and require RTCP keepalives to sustain streams
beyond ~1.8 seconds.

## Features

- Full RTSP state machine: OPTIONS → DESCRIBE → SETUP → PLAY
- TCP interleaved RTP/RTCP over TLS (`rtsps://`)
- H.264 hardware decoding via `VTDecompressionSession`
- Zero-copy frame delivery to Flutter via `TextureRegistry`
- Automatic self-signed certificate acceptance (required for Bambu Lab printers)
- RTCP Receiver Report keepalives to prevent stream stall
- Single-frame JPEG snapshot capture
- Up to 8 concurrent streams

## Requirements

- iOS 14.0+
- Swift 5.9+

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  flutter_rtsps_plugin:
    git:
      url: https://github.com/VIDGuide/flutter_rtsps_plugin.git
```

Then run:

```sh
flutter pub get
```

## Usage

### Live stream with Texture widget

```dart
import 'package:flutter_rtsps_plugin/flutter_rtsps_plugin.dart';
import 'package:flutter/material.dart';

class CameraView extends StatefulWidget {
  const CameraView({super.key});

  @override
  State<CameraView> createState() => _CameraViewState();
}

class _CameraViewState extends State<CameraView> {
  final _controller = RtspStreamController();
  int? _textureId;
  int? _streamId;

  @override
  void initState() {
    super.initState();
    _startStream();
  }

  Future<void> _startStream() async {
    try {
      final textureId = await _controller.startStream(
        'rtsps://bblp:<access_code>@<printer_ip>:322/streaming/live/1',
        'bblp',
        '<access_code>',
      );
      setState(() => _textureId = textureId);
    } on RtspException catch (e) {
      debugPrint('Stream error: ${e.code} — ${e.message}');
    }
  }

  @override
  void dispose() {
    if (_streamId != null) _controller.stopStream(_streamId!);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final id = _textureId;
    if (id == null) return const CircularProgressIndicator();
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Texture(textureId: id),
    );
  }
}
```

### Single-frame snapshot

```dart
final controller = RtspStreamController();
try {
  final jpeg = await controller.captureSnapshot(
    'rtsps://bblp:<access_code>@<printer_ip>:322/streaming/live/1',
    'bblp',
    '<access_code>',
    timeoutSeconds: 10,
  );
  // jpeg is a Uint8List — pass to Image.memory() or save to disk
} on RtspException catch (e) {
  debugPrint('Snapshot failed: ${e.code} — ${e.message}');
} finally {
  await controller.dispose();
}
```

## Self-signed certificate handling

Bambu Lab printers expose their camera stream over TLS using a **self-signed certificate**.
This plugin automatically accepts self-signed certificates on the `NWConnection` transport
layer via `sec_protocol_options_set_verify_block`, so no additional configuration is required
in your app. You do not need to add any certificate pinning exceptions or modify your iOS
`Info.plist`.

## Error handling

All errors are thrown as `RtspException` with a typed `code`:

| Code | Meaning |
|------|---------|
| `connectionFailed` | TCP/TLS connection could not be established |
| `authenticationFailed` | RTSP 401 — wrong username or password |
| `timeout` | No response within the timeout window |
| `noVideoTrack` | SDP contained no video media section |
| `decoderError` | VideoToolbox failed to initialise |
| `tooManyStreams` | 8 concurrent streams already active |

## License

MIT — see [LICENSE](LICENSE).
