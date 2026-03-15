import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_rtsps_plugin/flutter_rtsps_plugin.dart';

// Default URL — replace <access_code> and <printer_ip> with real values.
const String kDefaultUrl =
    'rtsps://bblp:<access_code>@<printer_ip>:322/streaming/live/1';
const String kDefaultUsername = 'bblp';
const String kDefaultPassword = '';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'RTSPS Plugin Example',
      home: StreamPage(),
    );
  }
}

class StreamPage extends StatefulWidget {
  const StreamPage({super.key});

  @override
  State<StreamPage> createState() => _StreamPageState();
}

class _StreamPageState extends State<StreamPage> {
  final _controller = RtspStreamController();

  late final TextEditingController _urlCtrl;
  late final TextEditingController _userCtrl;
  late final TextEditingController _passCtrl;

  int? _textureId;
  int? _streamId;
  String _status = 'Idle';
  Uint8List? _snapshotBytes;

  StreamSubscription<RtspStreamEvent>? _eventSub;

  @override
  void initState() {
    super.initState();
    _urlCtrl = TextEditingController(text: kDefaultUrl);
    _userCtrl = TextEditingController(text: kDefaultUsername);
    _passCtrl = TextEditingController(text: kDefaultPassword);
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _urlCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _startStream() async {
    setState(() => _status = 'Connecting...');
    try {
      final result = await _controller.startStream(
        _urlCtrl.text,
        _userCtrl.text,
        _passCtrl.text,
      );
      setState(() {
        _textureId = result.textureId;
        _streamId = result.streamId;
      });
      _eventSub = _controller.streamEvents(result.streamId).listen(
        (event) {
          switch (event) {
            case RtspPlayingEvent():
              setState(() => _status = 'Playing');
            case RtspErrorEvent(:final exception):
              setState(() => _status = 'Error: ${exception.message}');
            case RtspStoppedEvent():
              setState(() => _status = 'Stopped');
          }
        },
      );
    } on RtspException catch (e) {
      setState(() => _status = 'Error: ${e.message}');
    }
  }

  Future<void> _stopStream() async {
    if (_streamId == null) return;
    await _eventSub?.cancel();
    _eventSub = null;
    await _controller.stopStream(_streamId!);
    setState(() {
      _textureId = null;
      _streamId = null;
      _status = 'Stopped';
    });
  }

  Future<void> _captureSnapshot() async {
    setState(() => _status = 'Capturing snapshot...');
    try {
      final bytes = await _controller.captureSnapshot(
        _urlCtrl.text,
        _userCtrl.text,
        _passCtrl.text,
        timeoutSeconds: 10,
      );
      setState(() {
        _snapshotBytes = bytes;
        _status = 'Snapshot captured';
      });
    } on RtspException catch (e) {
      setState(() => _status = 'Error: ${e.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('RTSPS Plugin Example')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _urlCtrl,
              decoration: const InputDecoration(labelText: 'URL'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _userCtrl,
              decoration: const InputDecoration(labelText: 'Username'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _passCtrl,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password'),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: _textureId == null ? _startStream : null,
                    child: const Text('Start Stream'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _textureId != null ? _stopStream : null,
                    child: const Text('Stop'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _captureSnapshot,
                    child: const Text('Snapshot'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('Status: $_status'),
            const SizedBox(height: 12),
            if (_textureId != null)
              AspectRatio(
                aspectRatio: 16 / 9,
                child: Texture(textureId: _textureId!),
              ),
            if (_snapshotBytes != null) ...[
              const SizedBox(height: 12),
              Image.memory(_snapshotBytes!),
            ],
          ],
        ),
      ),
    );
  }
}
