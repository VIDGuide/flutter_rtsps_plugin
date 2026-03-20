# flutter_rtsps_plugin

A Flutter plugin for iOS that streams RTSP-over-TLS (`rtsps://`) video using Apple's
`NWConnection` (Network.framework) and `VideoToolbox`. Purpose-built for Bambu Lab printer
cameras, which use self-signed TLS certificates and require RTCP keepalives to sustain streams
beyond ~1.8 seconds.

## Features

- Full RTSP state machine: OPTIONS → DESCRIBE → SETUP → PLAY → TEARDOWN
- Automatic UDP transport negotiation with TCP interleaved fallback
- TCP interleaved RTP/RTCP over TLS (`rtsps://`)
- UDP RTP/RTCP media transport (bypasses TCP/TLS backpressure)
- H.264 hardware decoding via `VTDecompressionSession`
- Zero-copy frame delivery to Flutter via `TextureRegistry`
- Automatic self-signed certificate acceptance
- RTCP Receiver Reports with real jitter, fraction lost, LSR/DLSR (RFC 3550)
- Adaptive RTCP rate: 4x faster RRs during detected stalls
- Stall-resistant jitter computation (clamped to prevent feedback loops)
- SPS/PPS change detection to avoid unnecessary decoder reinit
- FU-A fragmentation reassembly and STAP-A aggregation
- Interleaved RTP frame handling during RTSP handshake
- Single-frame JPEG snapshot capture
- Up to 8 concurrent streams
- Digest authentication with qop=auth support (RFC 2617)
- Comprehensive diagnostic logging via `os_log`

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  RtspStreamManager                   │
│            (Flutter MethodChannel bridge)             │
├─────────────────────────────────────────────────────┤
│                 RtspStreamSession                    │
│          (owns all components per stream)             │
├──────────┬──────────┬───────────┬───────────────────┤
│ RtspState│ RtpDemux │ RtcpSender│ H264Decoder       │
│ Machine  │ er       │           │                   │
├──────────┤          │           ├───────────────────┤
│ RtspTrans│          │           │FlutterTextureOutput│
│ port(TLS)│          │           │                   │
├──────────┘          │           └───────────────────┘
│ UdpMedia            │
│ Transport           │
│ (optional)          │
└─────────────────────┘
```

### Component overview

| File | Responsibility |
|------|---------------|
| `RtspStreamManager.swift` | Flutter MethodChannel/EventChannel bridge, stream lifecycle |
| `RtspStreamSession.swift` | Coordinates all components for one stream |
| `RtspStateMachine.swift` | RTSP handshake, Digest auth, UDP/TCP SETUP negotiation |
| `RtspTransport.swift` | TLS TCP connection via NWConnection |
| `UdpMediaTransport.swift` | UDP RTP/RTCP sockets via NWConnection |
| `RtpDemuxer.swift` | TCP interleaved frame extraction, RTP parsing, FU-A/STAP-A |
| `RtcpSender.swift` | Periodic Receiver Reports, SR processing, stall detection |
| `H264Decoder.swift` | VideoToolbox H.264 decoding, SPS/PPS management |
| `FlutterTextureOutput.swift` | CVPixelBuffer → Flutter Texture bridge |
| `SnapshotCapture.swift` | Single-frame RTSP capture → JPEG |
| `SdpParser.swift` | SDP parsing for video track, SPS/PPS extraction |

## Transport negotiation

The plugin automatically negotiates the best transport for each stream:

1. During SETUP, the plugin first requests **UDP transport** (`RTP/AVP/UDP;unicast`)
2. If the server accepts (200 OK with `server_port=`), RTP/RTCP flow over UDP sockets
3. If the server rejects (461 Unsupported Transport), the plugin falls back to **TCP interleaved** (`RTP/AVP/TCP;unicast;interleaved=0-1`)

UDP transport is preferred because some Bambu printer firmware (notably the H2C) experiences
TCP/TLS backpressure on its ARM CPU, causing periodic 5-10 second stream stalls. The encoder
runs continuously but the TLS encryption layer can't drain the TCP send buffer fast enough,
causing frames to accumulate and flush in bursts. UDP bypasses this entirely — the RTSP
signaling still uses TLS/TCP, but the media stream flows over unencrypted UDP.

Snapshot captures always use TCP (no UDP negotiation) since they only need a single frame.

## RTCP implementation

The RTCP Receiver Report implementation follows RFC 3550 closely:

- Interarrival jitter computed per §6.4.1 / A.8, with a 50ms clamp to prevent
  stall-recovery bursts from inflating reported jitter (which could trigger
  server-side rate throttling)
- Jitter baseline resets after stall recovery so the first burst packet starts fresh
- Fraction lost and cumulative lost computed from extended sequence numbers
- LSR/DLSR computed from Sender Report NTP timestamps
- Immediate RR sent in response to each SR (some firmware gates encoder output on timely RR)
- Adaptive rate: switches from 1s to 250ms interval when no RTP packets arrive for >1.5s

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
in your app.

## TCP tuning

The TCP transport is configured for low-latency streaming:

- `noDelay = true` — disables Nagle's algorithm so small RTCP packets are sent immediately
- `enableKeepalive = true` with 5s idle — keeps the connection alive during stalls
- 10-second connection timeout

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

## Diagnostic logging

The plugin uses `os_log` with the subsystem `com.pandawatch.flutter_rtsps_plugin` and
per-component categories (`RtspStateMachine`, `RtpDemuxer`, `RtcpSender`, `H264Decoder`,
`UdpMediaTransport`, etc.). Key log points:

- Full RTSP handshake headers (OPTIONS, DESCRIBE, SETUP, PLAY)
- SDP body line-by-line
- Transport negotiation (UDP accepted/rejected, fallback to TCP)
- Periodic RTP statistics (packets/sec, bitrate, sequence numbers)
- Stall detection and recovery
- RTCP SR/RR exchange with jitter and loss metrics

## Support

If this plugin saves you some time, a coffee is always appreciated!

[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-support-yellow?logo=buy-me-a-coffee)](https://www.buymeacoffee.com/misaunders)

## License

MIT — see [LICENSE](LICENSE).
