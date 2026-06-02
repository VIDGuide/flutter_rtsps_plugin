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
  # Source files were moved under the Swift Package Manager directory layout.
  # Both CocoaPods and SwiftPM build from the same sources.
  s.source_files = 'flutter_rtsps_plugin/Sources/flutter_rtsps_plugin/**/*.swift'
  s.dependency 'Flutter'
  s.platform = :ios, '14.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.9'

  # Privacy manifest describing the plugin's (empty) privacy impact. Lives
  # alongside the sources under the SwiftPM layout; bundled here for CocoaPods.
  # See https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  s.resource_bundles = {'flutter_rtsps_plugin_privacy' => ['flutter_rtsps_plugin/Sources/flutter_rtsps_plugin/PrivacyInfo.xcprivacy']}
end
