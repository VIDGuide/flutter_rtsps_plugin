import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rtsps_plugin/flutter_rtsps_plugin.dart';
import 'package:flutter_rtsps_plugin/flutter_rtsps_plugin_platform_interface.dart';
import 'package:flutter_rtsps_plugin/flutter_rtsps_plugin_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockFlutterRtspsPluginPlatform
    with MockPlatformInterfaceMixin
    implements FlutterRtspsPluginPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final FlutterRtspsPluginPlatform initialPlatform = FlutterRtspsPluginPlatform.instance;

  test('$MethodChannelFlutterRtspsPlugin is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelFlutterRtspsPlugin>());
  });

  test('getPlatformVersion', () async {
    FlutterRtspsPlugin flutterRtspsPlugin = FlutterRtspsPlugin();
    MockFlutterRtspsPluginPlatform fakePlatform = MockFlutterRtspsPluginPlatform();
    FlutterRtspsPluginPlatform.instance = fakePlatform;

    expect(await flutterRtspsPlugin.getPlatformVersion(), '42');
  });
}
