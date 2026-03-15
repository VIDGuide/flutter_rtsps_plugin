import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'flutter_rtsps_plugin_method_channel.dart';

abstract class FlutterRtspsPluginPlatform extends PlatformInterface {
  /// Constructs a FlutterRtspsPluginPlatform.
  FlutterRtspsPluginPlatform() : super(token: _token);

  static final Object _token = Object();

  static FlutterRtspsPluginPlatform _instance = MethodChannelFlutterRtspsPlugin();

  /// The default instance of [FlutterRtspsPluginPlatform] to use.
  ///
  /// Defaults to [MethodChannelFlutterRtspsPlugin].
  static FlutterRtspsPluginPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [FlutterRtspsPluginPlatform] when
  /// they register themselves.
  static set instance(FlutterRtspsPluginPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
