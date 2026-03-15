#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_rtsps_plugin.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_rtsps_plugin'
  s.version          = '0.0.1'
  s.summary          = 'Flutter plugin for RTSP-over-TLS video streaming on iOS.'
  s.description      = <<-DESC
A Flutter plugin for iOS that streams RTSP-over-TLS (rtsps://) video using NWConnection
and VideoToolbox. Purpose-built for Bambu Lab printer cameras with self-signed TLS certificates.
                       DESC
  s.homepage         = 'https://github.com/pandawatch/flutter_rtsps_plugin'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'PandaWatch' => 'dev@pandawatch.app' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '14.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.9'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'flutter_rtsps_plugin_privacy' => ['Resources/PrivacyInfo.xcprivacy']}
end
