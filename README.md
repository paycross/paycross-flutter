# paycross_flutter

PayCross checkout for Flutter. One call presents the native PayCross payment
UI — card form, 3-D Secure v2 challenge, saved cards, status polling — and
returns one result. No card data ever passes through Dart.

Cards on both platforms, Google Pay on Android, and Apple Pay on iOS.

## Install

```yaml
dependencies:
  paycross_flutter: ^0.7.1
```

Then raise both platform minimums: `minSdk = 24` in your app's
`android/app/build.gradle.kts`, and `platform :ios, '16.0'` at the top of your
`ios/Podfile` with the Xcode deployment target to match. Neither default is high
enough, and both fail late — at the manifest merge and at pod resolution —
rather than at `pub get`. The [Flutter guide](https://docs.pay-cross.com/guides/flutter/)
covers this and the Swift Package Manager route.

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

`PayCrossResult` is sealed, so the switch is exhaustive and a case added later is
a compile error rather than a silently unhandled outcome. The
[example app](example/lib/main.dart) is this quickstart as a runnable screen.

## Documentation

- **[Flutter guide](https://docs.pay-cross.com/guides/flutter/)** — wallets,
  appearance, languages, saved cards, test identifiers, environments and errors.
- **[API reference](https://pub.dev/documentation/paycross_flutter/latest/)** on
  pub.dev.
- **[Changelog](https://docs.pay-cross.com/resources/changelogs/flutter/)** —
  mirrored from [`CHANGELOG.md`](CHANGELOG.md).
- **[Support](https://docs.pay-cross.com/resources/support/)** — where questions go.

## Contributing and security

Report a vulnerability the way [`SECURITY.md`](SECURITY.md) describes, never as a
public issue.

## License

MIT. See [LICENSE](LICENSE).
