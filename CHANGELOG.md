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
  `PayCrossRecovery` hint on declines, and `PayCrossIntegrationError` with
  stable `paycross_*` codes for integration mistakes.
* Sandbox and production environments; optional test-card prefill in sandbox.
* Android minSdk 24, iOS 16.0.

Known limitations:

* iOS is card-only: no Google Pay, and Apple Pay is on the roadmap.
* `brandColorArgb` and `googlePayMerchantId` apply on Android only and are
  ignored on iOS.
