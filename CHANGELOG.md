## 0.2.0

* Apple Pay on iOS. Pass `applePayMerchantId` to `PayCross.configure` and the
  native SDK renders Apple's own payment button inside the payment sheet. Your
  app adds no widget and implements no delegate; the result is the same
  `PayCrossResult` a card payment returns. The identifier must match the one
  saved on your PayCross merchant record — the edge compares them and refuses a
  payment whose two copies disagree. Android accepts and ignores it.
* The button appears only when the session loaded, the session allows wallets,
  an identifier is configured, and the device has a card it can pay with. It is
  absent and silent otherwise, including on account-funding sessions, on a
  simulator, and when the identifier is null, empty or whitespace-only — all
  three of which mean "not configured".
* Verify Apple Pay on a real device before shipping. `applePayMerchantId` and
  `googlePayMerchantId` are both nullable strings, so on iOS the two are
  indistinguishable to a compiler or a test suite; this release's iOS
  forwarding is covered by a device payment rather than by a unit test.
  Configure Apple Pay with `googlePayMerchantId` left null when you check it.
* Requires the native iOS SDK at PayCross 0.2.0, up from 0.1.1.

## 0.1.0

Initial release.

* Card payments through the native PayCross Android and iOS SDKs, presented
  from a single Dart call: `PayCross.presentPayment(sessionToken)`.
* 3-D Secure v2 challenges and status polling, handled entirely by the native
  SDKs — no card data passes through Dart.
* Saved cards, when the session's customer has any.
* Google Pay on Android: the native SDK shows the button when the session
  allows wallets and the device supports it. Pass `googlePayMerchantId` to
  `PayCross.configure` — Google requires it on production requests, though
  sandbox works without one.
* Sealed `PayCrossResult` (success / failure / cancelled) with a
  `PayCrossRecovery` hint on declines, and `PayCrossIntegrationError` for
  integration mistakes. Most of its codes map from stable `paycross_*` strings
  raised by the native SDKs; `testPrefillInProduction` is Dart-side only, raised
  before anything crosses the platform channel.
* Sandbox and production environments; optional test-card prefill in sandbox.
* Android minSdk 24, iOS 16.0.

Known limitations:

* iOS is card-only: no Google Pay, and Apple Pay is on the roadmap.
* `brandColorArgb` and `googlePayMerchantId` apply on Android only and are
  ignored on iOS.
