import 'dart:io';

import 'package:flutter_rtsps_plugin/flutter_rtsps_plugin.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RtspStreamController.maxConcurrentStreams', () {
    test('is exposed on the public API and is 8', () {
      expect(RtspStreamController.maxConcurrentStreams, 8);
    });

    // The native limit is a private Swift constant, so nothing at compile time
    // ties the two together. Read the Swift source and fail if they drift:
    // a mismatch would let callers reserve more capacity than the plugin can
    // serve, and the surplus startStream calls would fail with
    // RtspErrorCode.tooManyStreams.
    test('matches the private native RtspStreamManager.maxStreams', () {
      final swiftFile = File(
        'ios/flutter_rtsps_plugin/Sources/flutter_rtsps_plugin/'
        'RtspStreamManager.swift',
      );
      expect(
        swiftFile.existsSync(),
        isTrue,
        reason: 'Native RtspStreamManager.swift moved; update this test.',
      );

      final match = RegExp(r'static let maxStreams\s*=\s*(\d+)')
          .firstMatch(swiftFile.readAsStringSync());
      expect(
        match,
        isNotNull,
        reason: 'Could not find the maxStreams declaration in the Swift source.',
      );

      expect(
        int.parse(match!.group(1)!),
        RtspStreamController.maxConcurrentStreams,
        reason:
            'Dart maxConcurrentStreams has drifted from the native limit in '
            'RtspStreamManager.swift.',
      );
    });
  });
}
