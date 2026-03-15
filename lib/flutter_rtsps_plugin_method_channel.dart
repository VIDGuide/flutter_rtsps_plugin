import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'flutter_rtsps_plugin_platform_interface.dart';

/// An implementation of [FlutterRtspsPluginPlatform] that uses method channels.
class MethodChannelFlutterRtspsPlugin extends FlutterRtspsPluginPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('flutter_rtsps_plugin');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}
