Pod::Spec.new do |s|
  s.name             = 'paycross_flutter'
  s.version          = '0.3.0'
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

  # Classes/, not the template's paycross_flutter/Sources/ layout: the
  # hand-written Swift and the Pigeon output sit side by side under Classes/,
  # and the generated file has to be compiled with it.
  s.source_files = 'Classes/**/*.swift'

  s.dependency 'Flutter'
  s.dependency 'PayCross', '0.3.0'

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
