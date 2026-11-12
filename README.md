# paycross_flutter

PayCross checkout for Flutter. One call presents the native PayCross payment
UI — card form, 3-D Secure v2 challenge, saved cards, status polling — and
returns one result. No card data ever passes through Dart.

Cards on both platforms, Google Pay on Android, and Apple Pay on iOS.

## Install

```yaml
dependencies:
  paycross_flutter: ^0.7.5
```

Then raise both platform minimums: `minSdk = 24` in your app's
`android/app/build.gradle.kts`, and an iOS deployment target of at least 16.0.
Neither default is high enough, and both fail late — at the manifest merge and
at package resolution — rather than at `pub get`. iOS resolves the native SDK
through Swift Package Manager only, the default from Flutter 3.44. An app that
turned Swift Package Manager off must turn it on again: remove
`enable-swift-package-manager: false` from the `flutter: config:` block of its
`pubspec.yaml`, or run `flutter config --enable-swift-package-manager`. The
Flutter guide linked below covers both platforms.

## Quickstart

```dart
await PayCross.configure(environment: PayCrossEnvironment.sandbox);
final result = await PayCross.presentPayment(sessionToken);
switch (result) {
  case PayCrossSuccess(:final transactionId):        // paid; verify server-side
  case PayCrossFailure(:final recovery) when recovery.isRetryable: // retryable
  case PayCrossFailure():                            // declined, terminal
  case PayCrossPending(:final transactionId):        // unknown; reconcile first
  case PayCrossCancelled(:final transactionId):      // the shopper dismissed it
}
```

The [example app](example/lib/main.dart) is this quickstart as a runnable screen.

## Documentation

- **[Flutter guide](https://developers.pay-cross.com/guides/flutter/)** — wallets,
  appearance, languages, saved cards, test identifiers, environments and errors.
- **[API reference](https://pub.dev/documentation/paycross_flutter/latest/)** on
  pub.dev.
- **[Changelog](https://developers.pay-cross.com/resources/changelogs/flutter/)** —
  built from this repo's [`CHANGELOG.md`](CHANGELOG.md) at the latest released version.
- **[Support](https://developers.pay-cross.com/resources/support/)** — questions go to support@pay-cross.com.

## Contributing and security

Report a vulnerability the way [`SECURITY.md`](SECURITY.md) describes, never as a
public issue.

## License

MIT. See [LICENSE](LICENSE).
