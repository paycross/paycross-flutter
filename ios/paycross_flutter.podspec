Pod::Spec.new do |s|
  s.name             = 'paycross_flutter'
  s.version          = '0.7.4'
  s.summary          = 'PayCross payment SDK for Flutter.'
  s.description      = <<-DESC
    Presents the native PayCross payment sheet from Flutter: card entry, 3-D
    Secure v2 and status polling. Wraps the native iOS SDK rather than
    reimplementing it, so no card data passes through Dart.
  DESC
  s.homepage         = 'https://github.com/paycross/paycross-flutter'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = 'PayCross'
  s.source           = { :path => '.' }

  # Recursive, so the generated Pigeon sources under generated/ are compiled too.
  s.source_files = 'paycross_flutter/Sources/paycross_flutter/**/*.swift'

  # CocoaPods ignores Package.swift's resources, so the privacy manifest is declared here too. Apple reads it from the built bundle; a missing one is silent in the build log.
  s.resource_bundles = {
    'paycross_flutter_privacy' => ['paycross_flutter/Sources/paycross_flutter/PrivacyInfo.xcprivacy']
  }

  s.dependency 'Flutter'
  s.dependency 'PayCross', '0.8.0'

  # Matches the wrapped SDK's iOS 16 minimum; CocoaPods reports a mismatch only as a resolution failure.
  s.platform = :ios, '16.0'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    # Flutter.framework has no i386 architecture.
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    # The wrapped SDK uses Swift 6 strict concurrency, which Pods do not inherit from Package.swift.
    'SWIFT_VERSION' => '6.0'
  }
  s.swift_version = '6.0'
end
