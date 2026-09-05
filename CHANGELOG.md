## Unreleased

Additive in Dart. No existing call or `switch` needs a change.

* `PayCrossSuccess.savedCardToken` is the vault reference for a card the
  payment just saved, and null on every payment that saved none — including one
  made with a card that was already stored. It is the same value the merchant
  API returns as `stored_credentials.saved_token`, and it is what you send to
  charge that card again, so store it against your customer. Until now a
  merchant who offered "save this card" had no way to learn the token from the
  SDK at all. Saving is asked for at session creation with `save_card_config`;
  nothing on this side turns it on.
* Requires the native iOS SDK at PayCross 0.5.0, up from 0.4.0, and the native
  Android SDK at paycross-android 0.6.0, up from 0.5.0. Both add the token
  above, and both add two saved-card behaviours the sheets render on their own:
  `saved_cards.allow_removal` puts a confirmed delete on each stored card, and
  `saved_cards.preselect` opens the sheet with the most recently used one
  chosen. Both are session options and default to off, so a session minted
  before the backend shipped them reads as off, and there is nothing to call
  from Dart for either. A saved card still asks for its CVC on every payment.
* The demo app names the saved-card token on an approved payment.

## 0.4.0

Source-incompatible. `PayCrossResult` gains a case, so an exhaustive `switch`
in merchant code needs a branch for it.

* `PayCrossPending` is a new `PayCrossResult` case: the payment's outcome was
  never observed, and it **may have succeeded**. Until now that outcome arrived
  as a `PayCrossFailure` carrying `RecoveryVerifyBeforeRetry`, which is to say
  it looked like a decline — and it is the one outcome where treating it as a
  decline and charging again can charge the shopper twice. It carries the
  `transactionId` to reconcile against, a `reason`
  (`PayCrossPendingReason.pollTimeout`, `resultLost` or `serverVerify`) and the
  raw wire name in `reasonRaw`, kept for a reason this version cannot read.
  Every reason means the same thing for what the merchant must do next:
  reconcile server-side, never retry blindly.
* A lost result is a `PayCrossPending` with reason `resultLost` rather than a
  thrown `PayCrossIntegrationError`. `PayCrossErrorCode.resultUnknown` is
  deprecated and is never thrown; the enum member and its code mapping stay for
  one minor so an existing `switch` over the codes still compiles. It was the
  one error code that never meant a mistake in merchant code, which is why it
  belongs in the result switch instead — where the compiler asks for a decision
  rather than leaving it to a `catch` block written once and forgotten.
* `RecoveryVerifyBeforeRetry` is no longer reachable through `presentPayment`.
  Both native SDKs now send that outcome as a pending result, and the plugin
  maps the recovery to `PayCrossPending` defensively as well, so a merchant
  pinning an older native SDK under this plugin still gets the safe reading.
  The case itself stays: `PayCrossRecovery.fromApiValue` is public and still
  parses the token, still not retryable.
* Requires the native iOS SDK at PayCross 0.4.0, up from 0.3.0, and the native
  Android SDK at paycross-android 0.5.0, up from 0.4.0. Both native releases
  introduced the pending outcome; this release is the plugin bridging it.
* The iOS implementation moves to a Swift Package Manager layout under
  `ios/paycross_flutter/Sources/paycross_flutter/`, with a `Package.swift` and
  a privacy manifest. Merchants on CocoaPods need no change — the podspec
  points at the new path — and merchants on Flutter's Swift Package Manager
  support no longer pull CocoaPods in for this plugin.
* The demo app renders the new outcome, and the E2E automation contract gains
  `result:pending:<reason>:<txn>`.

## 0.3.0

Source-incompatible. The plugin's own result types change, so this is a minor
bump and an exhaustive `switch` in merchant code needs updating.

* `PayCrossCancelled` carries `transactionId`, the last transaction the session
  created, or null when the sheet was dismissed before one existed. Dismissing
  the sheet does not cancel the authorization: a shopper can walk away after a
  decline or part-way through a 3-D Secure challenge, and the server keeps its
  own record of the attempt. Until now there was nothing in the result to
  reconcile it against. Constructing `PayCrossCancelled()` still compiles;
  code that destructures it exhaustively gains a field.
* `RecoveryVerifyBeforeRetry` is a new `PayCrossRecovery` case, from the wire
  token `verify_before_retry`. It means the native SDK's status poll ran out of
  time and never observed the outcome, so the payment may have succeeded and
  shifted liability. It is not retryable, which is the point: this is the one
  recovery where trying again can charge a shopper twice. A `switch` over
  `PayCrossRecovery` needs a branch for it; code that checks
  `recovery.isRetryable` rather than matching cases needs no change and gets
  the safe answer already.
* An unrecognised recovery from an Android session now reaches Dart with the
  server's own string, so it lands on `RecoveryUnrecognized(value)` instead of
  being reported as a terminal decline. Previously only iOS could produce that
  case. Both platforms now agree on the same server response, which was the
  point of the asymmetry note this release removes.
* Requires the native iOS SDK at PayCross 0.3.0, up from 0.2.1, and the native
  Android SDK at paycross-android 0.4.0, up from 0.3.4. Both native releases
  carry the same three changes; this release is the plugin catching up to them.

## 0.2.1

* Apple Pay and Google Pay are now offered on account-funding sessions, not
  only on payment sessions. The wallet buttons appear under the same rules as
  before — session loaded, session allows wallets, an identifier configured,
  a device that can pay — the change is that an account-funding session can
  now satisfy "session allows wallets" instead of always failing it. The
  plugin has no session-type logic of its own; this follows entirely from the
  native SDK bump below.
* Requires the native iOS SDK at PayCross 0.2.1, up from 0.2.0, and the native
  Android SDK at paycross-android 0.3.4, up from 0.3.3.
* An explicit `wallets.apple_pay: false` or `wallets.google_pay: false` on the
  session still hides the corresponding button, on either session type.

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
