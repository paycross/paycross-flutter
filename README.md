# paycross_flutter

PayCross checkout for Flutter. One call presents the native PayCross payment
UI — card form, 3-D Secure v2 challenge, saved cards, status polling — and
returns one result. No card data ever passes through Dart.

Cards on both platforms, plus Google Pay on Android. Apple Pay is on the
roadmap.

## Requirements

| Platform | Minimum |
|----------|---------|
| Android | minSdk 24 (Android 7.0) |
| iOS | 16.0 |

## Install

```yaml
dependencies:
  paycross_flutter: ^0.1.0
```

## Quickstart

Configure once, before taking a payment:

```dart
await PayCross.configure(environment: PayCrossEnvironment.sandbox);
```

Then present a payment with a session token and switch over the result:

```dart
final result = await PayCross.presentPayment(sessionToken);

switch (result) {
  case PayCrossSuccess(:final transactionId, :final amount):
    // Paid. Fulfil the order; verify server-side against transactionId.
  case PayCrossFailure(:final recovery) when recovery.isRetryable:
    // Declined, but the shopper may try again in the same session.
  case PayCrossFailure():
    // Declined, terminal for this session.
  case PayCrossCancelled():
    // The shopper dismissed the sheet.
}
```

The switch is exhaustive: `PayCrossResult` is sealed, so a result case added in
a future version is a compile error rather than a silently unhandled outcome.

The [example app](example/lib/main.dart) is this quickstart as a runnable
screen, including the error handling below.

### Session tokens

`presentPayment` takes no amount, currency or customer. All of that is carried
by the session token, which your **server** creates against the PayCross API
and hands to the app. The client cannot alter what is charged; it can only
present the session it was given.

### The call can take minutes

The SDK polls the server for up to eight minutes, and a 3-D Secure challenge
waits on the shopper's bank. Do not wrap the returned Future in
`Future.timeout`: abandoning the Future does not stop the native payment, and
the card may still be charged.

## Environments

| Environment | Backend | Cards |
|-------------|---------|-------|
| `PayCrossEnvironment.sandbox` | Test | Test cards only |
| `PayCrossEnvironment.production` | Live | Real money |

In sandbox, `PayCrossTestCardPrefill` can pre-fill the card form; combining a
prefill with production throws.

## Errors

A decline is **not** an error — it arrives as `PayCrossFailure` with a
`PayCrossRecovery` hint. Thrown errors are always `PayCrossIntegrationError`,
meaning the SDK was asked to do something it cannot:

| Code | Meaning |
|------|---------|
| `notConfigured` | `PayCross.configure` was never called in this process. |
| `busy` | A payment is already in flight. One at a time, per process. |
| `noActivity` | Android: the plugin is not attached to an Activity, or the host Activity uses a launchMode that cannot receive results. |
| `noPresenter` | iOS: no view controller to present from. |
| `invalidToken` | The session token was empty. |
| `resultUnknown` | The payment's outcome is genuinely unknown — the engine or Activity was destroyed mid-flight. It **may have succeeded**; reconcile server-side rather than re-charging. |
| `unknown` | Anything the plugin did not recognise. |

Every code except `resultUnknown` points at a fixable mistake in merchant code.

## Google Pay

On **Android**, the native SDK renders the Google Pay button itself, without
any extra call: it appears when the payment session allows wallets, the device
supports Google Pay, and the session is not an account-funding one — and is
simply absent otherwise. There is no flag to turn it on.

Going live needs one thing from you — the merchant id from your
[Google Business Console](https://pay.google.com/business/console), which Google
requires on **production** Google Pay requests:

```dart
await PayCross.configure(
  environment: PayCrossEnvironment.production,
  googlePayMerchantId: 'BCR2DN4T...',
);
```

Sandbox works without one, so a missing merchant id is invisible in testing and
only breaks the wallet in production. Configure it before you ship.

**iOS is card-only.** It has no Google Pay, `googlePayMerchantId` is accepted
and ignored there, and Apple Pay is on the roadmap.

## Branding

`brandColorArgb` in `PayCross.configure` currently applies on **Android only**;
the iOS SDK exposes no brand-colour hook, so it is ignored there.

## License

Proprietary. See [LICENSE](LICENSE).
