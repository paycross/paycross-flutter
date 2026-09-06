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
  paycross_flutter: ^0.6.0
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

### Swift Package Manager

The plugin ships a `Package.swift` as well as a podspec, so it works on either
iOS package manager. Flutter's Swift Package Manager support is off by default;
turn it on with `flutter config --enable-swift-package-manager` and there is
nothing else to do — the deployment target above still applies, and there is no
`pod install` step. Both routes resolve the same native SDK release, so the
choice does not change what your app links against.

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

### Saved cards

A card is saved because the **session** asked for it: `save_card_config` on
session creation, not a client call. When a payment saves one,
`PayCrossSuccess.savedCardToken` carries the vault reference — the same value
the merchant API returns as `stored_credentials.saved_token`. Store it against
your customer; it is what you send to charge that card again. It is null on
every payment that saved nothing.

Showing a shopper the cards they already saved is a session option too:
`saved_cards.show: "all"` lists them (or `saved_cards.tokens` names which ones;
`show` is not a boolean), `saved_cards.preselect` opens the sheet with the
most recently used one chosen, and `saved_cards.allow_removal` lets the
shopper delete one. The native
sheets render all of it, so there is nothing to build and nothing to call from
Dart. CVC is always asked for on a saved card.

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

## Languages

The native payment sheets ship English and French. The demo app's own screens
and yours are untouched by this: it is the sheet's language only.

| Language | Tag |
|---|---|
| English | `en` |
| French | `fr` |

Pin it when your app already knows what the shopper reads:

```dart
await PayCross.configure(
  environment: PayCrossEnvironment.production,
  locale: 'fr',
);
```

The language is the first of four candidates that names a language the SDKs
ship: your `locale`, then the payment session's own `locale`, then the shopper's
device languages, then English. Each is matched on its own — the whole tag,
then its primary subtag, so `fr-CA` gets French — and one that matches nothing
falls through to the next rather than ending the ladder. So `locale: 'de'` over
a French session still draws French.

The **amount** is not clamped to those two languages. It is formatted with the
first locale anyone named, region intact, so a German shopper reads an English
sheet over a `12,34 €` amount rather than losing their own number formatting to
a language the SDKs have no words for.

This package passes the tag across exactly as you write it. It does not
resolve, validate or normalise it, because both native SDKs already do all of
that and a second opinion here could only disagree with them. A malformed tag
is skipped by the native resolver rather than thrown on, so nothing you pass
can fail a payment. Null — the default — is the ladder's first rung left
empty, not a request for English.

Every string each sheet draws is overridable in your own app, and the two
`LOCALIZATION.md` files are the full lists:
[Android](https://github.com/paycross/payment-android-sdk/blob/main/LOCALIZATION.md),
[iOS](https://github.com/paycross/payment-ios-sdk/blob/main/LOCALIZATION.md).

## Test identifiers

Every element the sheets draw carries a stable identifier, and **it is the same
string on both platforms**, so one selector in your integration tests finds the
same element on Android and iOS. They are all named `paycross.*` —
`paycross.cardNumber`, `paycross.payButton`, `paycross.savedCard.<uuid>` and so
on. The full tables are in the native READMEs:
[Android](https://github.com/paycross/payment-android-sdk#test-identifiers),
[iOS](https://github.com/paycross/payment-ios-sdk#test-identifiers).

Two things to know before you write the selectors:

- **On Android they are a debug-build contract.** The identifiers reach a
  UiAutomator or Espresso tree only when the host app is debuggable; a release
  build publishes none of them, because they would hand the sheet's structure,
  and a stored card's uuid with it, to any accessibility service on the device.
  An ordinary `androidTest` run already builds the debug variant and needs
  nothing extra. A suite that runs against a release build needs a debuggable
  variant of its own. On iOS they are set in every build, because an
  `accessibilityIdentifier` is not surfaced to VoiceOver or to other apps and
  so has nothing to gate.
- **Three names are iOS-only**, because Android draws no element behind them:
  `paycross.brand` (the detected card brand badge), `paycross.threeDSCancel`
  and `paycross.cancel`. The Android sheet has no close control of its own — it
  is cancelled with the system back gesture — so from an Android test, press
  back and then use `paycross.cancelConfirm`.

## Appearance

The native sheets take a `PayCrossAppearance`: colours per mode, a theme mode,
corner radii, the Pay button and a font scale. It applies on both platforms.

```dart
await PayCross.configure(
  environment: PayCrossEnvironment.production,
  appearance: const PayCrossAppearance(
    light: PayCrossColors(
      brand: Color(0xFF1E88E5),
      surface: Color(0xFFFAFAFA),
      component: Color(0xFFFFFFFF),
      componentBorder: Color(0xFFDDDDDD),
      text: Color(0xFF111111),
      textSecondary: Color(0xFF666666),
      placeholder: Color(0xFF999999),
      icon: Color(0xFF444444),
      error: Color(0xFFB3261E),
    ),
    dark: PayCrossColors(
      brand: Color(0xFF64B5F6),
      surface: Color(0xFF121212),
      component: Color(0xFF1E1E1E),
    ),
    themeMode: PayCrossThemeMode.system,
    shapes: PayCrossShapes(
      cornerRadius: 16,
      buttonCornerRadius: 28,
      borderWidth: 1,
    ),
    primaryButton: PayCrossPrimaryButton(height: 56),
    typography: PayCrossTypography(sizeScaleFactor: 1.1),
  ),
);
```

For one colour and nothing else, `PayCrossAppearance.brand(color)` fills the
brand role in both palettes and leaves the rest alone.

### Which colour wins

Every role resolves in the same order:

1. what you set in `PayCrossAppearance`,
2. the brand colour set on the merchant account in the PayCross back office,
   which arrives with the session and feeds the `brand` role in both modes,
3. the platform default the sheet already draws.

So **a brand colour set in the back office themes both sheets with no code at
all**, and a null role is never "black" — it is "take the next source".

`onBrand` is the one role with a rule of its own: left null, each SDK derives
it from the brand colour's own luminance, so a light brand gets a dark label
rather than an unreadable white one.

`themeMode` pins the **sheet** and nothing else. It never touches the host
app's own appearance.

### What you cannot change

Fixed by design, and passing an appearance does not reach any of it:

* the sheet's layout,
* the card inputs' internals — masking, formatting, validation, the keyboard,
* the Apple Pay and Google Pay buttons' colours and labels, which Apple's and
  Google's own guidelines specify. Their corner radius follows
  `shapes.buttonCornerRadius`, and that is the only property of theirs this SDK
  sets,
* the 3-D Secure page, which is the issuer's own content,
* the error copy.

A font family is not exposed in this release.

### Ranges

`sizeScaleFactor` must be between **0.8 and 1.3** inclusive, and it multiplies
the shopper's own text-size setting rather than replacing it. Every radius,
border width and height must be finite and not negative; zero is legal and
means a square corner, no border, or the platform's own height.

Anything outside those bounds throws `PayCrossIntegrationError` with
`PayCrossErrorCode.invalidAppearance` from `configure`, before it reaches
either native SDK.

Sizes are in the platform's own unit — density-independent pixels on Android,
points on iOS — and are not converted between them.

### Migrating from `brandColorArgb`

`brandColorArgb` is deprecated and still works for now. Replace it with:

```dart
appearance: PayCrossAppearance.brand(Color(0xFF6750A4)),
```

Setting both is not an error, and it does not lose your colour. The appearance
decides only what it actually names:

* if either palette sets `brand`, that wins and `brandColorArgb` is ignored;
* if neither does — an appearance that is only shapes, or only a font scale,
  which is what a half-finished migration looks like — `brandColorArgb` is
  merged into `brand` in **both** palettes.

Either way the legacy value is not sent to the native SDKs on its own, so
neither has to decide which of two brand colours is the real one.

`PayCrossColors` and `PayCrossAppearance` both have a `copyWith` if you want to
build a palette up in steps. Passing null to it keeps the value already there
rather than clearing it, which is the usual Flutter bargain: construct a fresh
palette to unset a role.

## License

MIT. See [LICENSE](LICENSE).
