# paycross_flutter

PayCross checkout for Flutter. One call presents the native PayCross payment
UI — card form, 3-D Secure v2 challenge, saved cards, status polling — and
returns one result. No card data ever passes through Dart.

Cards on both platforms, Google Pay on Android, and Apple Pay on iOS.

## Requirements

| Platform | Minimum |
|----------|---------|
| Android | minSdk 24 (Android 7.0) |
| iOS | 16.0 |

## Install

```yaml
dependencies:
  paycross_flutter: ^0.2.1
```

Then raise both platform minimums to match the table above. Neither default is
high enough, and both fail late — Android at the manifest merge, iOS during pod
resolution — rather than at `pub get`.

**Android** — in your app's `android/app/build.gradle.kts`:

```kotlin
android {
    defaultConfig {
        minSdk = 24
    }
}
```

(`android/app/build.gradle` if your project still uses the Groovy DSL.)

**iOS** — the first line of your app's `ios/Podfile`:

```ruby
platform :ios, '16.0'
```

Bump the deployment target in Xcode to match (Runner target → General → Minimum
Deployments), then `cd ios && pod install`.

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
  case PayCrossPending(:final transactionId):
    // Outcome unknown. Reconcile server-side before charging again.
  case PayCrossCancelled(:final transactionId):
    // The shopper dismissed the sheet. Dismissing it does not cancel the
    // authorization, so transactionId names the attempt they left behind,
    // or is null if there was none yet.
}
```

The switch is exhaustive: `PayCrossResult` is sealed, so a result case added in
a future version is a compile error rather than a silently unhandled outcome.

### The unresolved outcome

`PayCrossPending` is neither a success nor a decline: the SDK never saw a
verdict. A payment that completed and shifted liability looks exactly like one
that never happened, so this is the only outcome where charging again can
charge the shopper twice. Reconcile server-side against `transactionId` — which
is null only when the result was lost before a transaction was known — and
never retry blindly or show the shopper a decline. `reason` says why the
outcome is unknown (`pollTimeout`, `resultLost`, `serverVerify`), and
`reasonRaw` carries the wire name verbatim for a reason this version cannot
read. Every reason means the same thing for what you must do next.

The [example app](example/lib/main.dart) is this quickstart as a runnable
screen, including the error handling below. It ships as **PayCross Demo — the
internal QA app ([`example/`](example/README.md))**, which mints its own
sandbox sessions and runs named payment scenarios.

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
prefill with production throws `testPrefillInProduction`.

## Errors

A decline is **not** an error — it arrives as `PayCrossFailure` with a
`PayCrossRecovery` hint, and an outcome the SDK never observed is not an error
either — it arrives as `PayCrossPending`. Check `recovery.isRetryable` rather
than matching on cases: it is a whitelist, so anything the SDK could not read
fails closed. `RecoveryUnrecognized` is worth naming, because it carries the
server's own token for a value this version does not know and is not retryable.

Thrown errors are always `PayCrossIntegrationError`, meaning the SDK was asked
to do something it cannot:

| Code | Meaning |
|------|---------|
| `notConfigured` | `PayCross.configure` was never called in this process. |
| `testPrefillInProduction` | A `PayCrossTestCardPrefill` was passed to `PayCross.configure` together with `PayCrossEnvironment.production`. Prefills are sandbox-only. |
| `busy` | A payment is already in flight. One at a time, per process. |
| `noActivity` | Android: the plugin is not attached to an Activity, or the host Activity uses a launchMode that cannot receive results. |
| `noPresenter` | iOS: no view controller to present from. |
| `invalidToken` | The session token was empty. |
| `resultUnknown` | **Deprecated, no longer thrown.** A lost result is a `PayCrossPending` with reason `resultLost` since 0.4.0. The enum member stays for one minor so an existing `switch` still compiles. |
| `unknown` | Anything the plugin did not recognise. |

Every code here points at a fixable mistake in merchant code.

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

**iOS has no Google Pay.** Google Pay's in-app API is Android and web only, so
`googlePayMerchantId` is accepted and ignored on iOS. The iOS wallet is Apple
Pay, and it has its own section below.

## Apple Pay

On **iOS**, the native SDK renders Apple's own payment button inside the payment
sheet, above the card form, without any extra call or widget in your app.
Tapping it presents Apple's sheet and resolves to the same `PayCrossResult` a
card payment does.

The button appears only when all four of these hold, and is simply absent
otherwise:

- the payment session loaded;
- the session allows wallets;
- an Apple merchant identifier is configured;
- the device has a card it can pay with.

So there are five ways to end up with no button, and none of them is an error:

- **The session did not load.** A transport failure and a 5xx look the same
  from here, and a button that opens onto nothing is worse than no button.
- **The session is an account-funding one.** PayCross rejects wallet payments
  on those, so a button would buy a Face ID prompt and a rejection.
- **No identifier is configured.** Null, empty and whitespace-only all count as
  not configured — the SDK trims before deciding, because an empty build
  constant and a hand-cleared text field are the two ways this goes wrong.
- **The device has no card**, or Apple Pay is unavailable on it.
- **You are on a simulator.** `canMakePayments` is false on a simulator with an
  empty Wallet. Apple Pay can only be exercised on a real device with a
  provisioned card.

Going live takes six steps, and skipping them leaves the card form only —
nothing breaks:

1. Ask PayCross to enable Apple Pay for your merchant account.
2. Download PayCross's Apple Pay certificate request (`.csr`) from the back
   office. It is the same file for every merchant in that environment.
3. In your own Apple Developer team, create a Merchant ID, upload that
   certificate request, and let Apple issue the payment-processing certificate.
4. Tell PayCross that Merchant ID, in the back office's Apple merchant
   identifier field. PayCross cannot derive it, and the vault cannot decrypt a
   payment token without it.
5. In Xcode, add the Apple Pay capability to the app id and tick that Merchant
   ID. This is what puts the identifier into the app's
   `com.apple.developer.in-app-payments` entitlement.
6. Pass the same string to `PayCross.configure`:

```dart
await PayCross.configure(
  environment: PayCrossEnvironment.production,
  applePayMerchantId: 'merchant.example.com',
);
```

The same steps, with more of the iOS detail, are in the
[native SDK's README](https://github.com/paycross/payment-ios-sdk#apple-pay).

**The identifier in step 6 and the identifier in step 4 must be the same
string.** Apple hashes it into the key that encrypts every payment token, so
when the two disagree nothing downstream can decrypt what the device produced.
PayCross refuses such a payment at the edge and returns a sentence saying so.
Null — the default — means not configured, and there is simply no button.

**Android ignores `applePayMerchantId`**, as there is no Apple Pay there.

**Test it on a device before you ship.** `applePayMerchantId` and
`googlePayMerchantId` are both nullable strings, so nothing a compiler or a test
suite can see distinguishes them once they reach iOS. Configure Apple Pay with
`googlePayMerchantId` left null, run a payment on a real device, and confirm the
button appears and the payment settles.

## Branding

`brandColorArgb` in `PayCross.configure` currently applies on **Android only**;
the iOS SDK exposes no brand-colour hook, so it is ignored there.

## License

MIT. See [LICENSE](LICENSE).
