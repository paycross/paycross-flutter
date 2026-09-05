Pod::Spec.new do |s|
  s.name             = 'paycross_flutter'
  s.version          = '0.5.0'
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

  # The same tree Package.swift compiles, so CocoaPods and Swift Package
  # Manager cannot drift into building different sources. The glob is recursive
  # because the Pigeon output sits in a generated/ subdirectory and has to be
  # compiled with the hand-written Swift beside it.
  s.source_files = 'paycross_flutter/Sources/paycross_flutter/**/*.swift'

  # CocoaPods does not read Package.swift's `resources:`, so the privacy
  # manifest is declared again here. Apple reads it out of the built bundle,
  # and a pod that shipped without one would be rejected at App Store submission
  # with nothing in the build log to point at.
  s.resource_bundles = {
    'paycross_flutter_privacy' => ['paycross_flutter/Sources/paycross_flutter/PrivacyInfo.xcprivacy']
  }

  s.dependency 'Flutter'
  s.dependency 'PayCross', '0.5.0'

  # 16.0, not the template's 13.0: PayCross declares platforms: [.iOS(.v16)],
  # and CocoaPods surfaces that mismatch as an opaque resolution failure rather
  # than a legible minimum-version error. Stated here, where a merchant sees it.
  s.platform = :ios, '16.0'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    # Flutter.framework does not contain an i386 slice.
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    # The wrapped SDK is written against Swift 6 strict concurrency, and a Pods
    # project does not inherit .swiftLanguageMode(.v6) from Package.swift.
    'SWIFT_VERSION' => '6.0'
  }
  s.swift_version = '6.0'
end
