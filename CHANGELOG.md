## Unreleased

Demo only. No Dart API change, and `lib/` is untouched.

* The demo app is 0.1.14. Nothing in the app itself changed. The release exists
  so a tester on the internal track drives the sheet from plugin 0.7.2, and so
  the first built demo carrying paycross-android 0.8.3 and PayCross 0.7.2 is a
  signed one: a merchant's own field labels, placeholders, select options and
  validation messages drawn in the language the sheet resolved, and an Android
  wallet tap that no longer marks the card fields invalid. Every demo before it
  ran the sheet from 0.8.1 and 0.7.1.

## 0.7.2

Pins the native releases paycross-android 0.8.3 and PayCross 0.7.2. No Dart API
change, and `lib/` is untouched; everything below the native bullets is the demo
and the E2E runner.

* A merchant's own server-driven fields are drawn in the sheet's language. The
  group heading, each field's label and placeholder, each select option and each
  of a field's validation messages come from the payment session, and both
  sheets drew them in the language the session was minted for — so a French
  shopper met an English `Billing address` under French chrome. The session now
  carries each of those strings in every language the checkout API renders,
  keyed by language tag, beside the single value it always sent, and the sheet
  reads the entry for the language it already resolved for its own copy. Nothing
  is translated on the device. A session carrying only that single value, which
  is every session minted before the API change and there are live ones, draws
  exactly what it drew before. The plugin hands the sheet a `locale` and renders
  none of these strings itself, so a merchant gets this by taking the release:
  no code change, no new option.
* Tapping Google Pay on Android no longer marks the card fields invalid. One
  flag revealed validation for both of the sheet's validated surfaces, so the
  wallet tap drew the card number, expiry, CVV and cardholder name in error — a
  form the shopper had not typed in, and one the wallet branch never submits.
  Each surface has its own flag now.
* The Android SDK is MIT-licensed from 0.8.2, matching this plugin and the iOS
  SDK. It was proprietary and all-rights-reserved while its sources shipped to
  Maven Central. Artifacts published before 0.8.2 keep the old licence block,
  because a coordinate on Central is permanent.
* The example app declares `CFBundleLocalizations` — `en` and `fr` — in its iOS
  `Info.plist`. It ships no `.lproj` folder for either and needs none: the key
  is a declaration, and the SDK carries its own French strings inside its own
  bundle. What it buys is the demo's own `Locale.current`, and it is what a
  merchant app integrating the SDK will want for the same reason.
* The E2E runner can put a device in another language and prove that it took.
  `device_language <tag>` writes the app's own locale list on Android and reads
  it back — `cmd locale set-app-locales` reports nothing at all whether it
  worked or not — and passes the list as a launch argument on iOS. `default`
  puts the device back, and the runner replays that for a cell that died
  holding it.
* A cell can assert that the sheet reads in French: `expect french_sheet` looks
  at the Pay button's caption for the French verb. The D6 dimension gains
  `french_device`, which mints a session naming a language neither SDK ships so
  the ladder falls past it to the device, and `french_session` now asserts the
  copy it only used to pay through.
* The example app's Settings screen gains an appearance editor: a brand colour
  for light mode and one for dark, whether the sheet follows the phone or is
  pinned to one palette, the corner radius, the button corner radius and a font
  scale. It is kept in `SharedPreferences` beside the language and read once at
  launch, so a restart applies it. "Load the themed preset" fills the fields in
  with what the Themed sheet tile on Home runs and leaves them editable; that
  tile is unchanged. Merchants evaluating the SDK could not try a colour of
  their own before this — the app had one hard-coded theme and no way in.
* Every number `PayCross.configure` refuses is refused in the field it was
  typed in: a font scale outside 0.8 to 1.3, a negative or non-numeric radius,
  a brand colour that is not six or eight hex digits. The launch awaits
  `configure` before the first frame and does not catch it, so a stored value
  the SDK would raise on is a blank app rather than an odd-looking sheet — and
  the stored string is not always one this build wrote.
* A themed run and a trip through Live now put the chosen theme back rather
  than clearing it. Re-pointing the SDK replaces the whole configuration, so
  the launch appearance travels with the wallet identifiers and the locale, and
  `null` means "as it was at launch" rather than "unthemed". The theme is
  deliberately not sent to production: a brand colour belongs to a merchant,
  and the merchant in Live is a different one whose colour is set in its own
  back office.
* The automation build takes an appearance from
  `--dart-define=PAYCROSS_APPEARANCE=<json>`, so a matrix cell can run a themed
  sheet and screenshot it. The JSON is the editor's own six fields, all
  optional:
  `{"brandLight":"00875A","brandDark":"57D9A3","themeMode":"dark","cornerRadius":16,"buttonCornerRadius":28,"fontScale":1.2}`.
  A string the build cannot read costs the cell its theme and says so on the
  log rather than costing it the launch. Running a themed cell used to mean
  editing the entrypoint by hand for the duration of a smoke.
* The iOS driver matches the system's paste item in French as well as English.
  It is UIKit's edit menu rather than anything the demo draws, so it moves with
  the app's language and took `paste_token` with it.
* The Android driver's `adb` default is `adb.exe` off `PATH` rather than one
  workstation's SDK directory, which is not a path a public repository should
  carry. `PAYCROSS_E2E_ADB` still names a specific binary, and setting it is
  what a rig whose `platform-tools` are not on `PATH` now does.

## 0.7.1

Pins the native patch releases paycross-android 0.8.1 and PayCross 0.7.1: every
`paycross.*` identifier now reaches the platform's accessibility tree (Android's
wallet button and 3-D Secure wrappers; iOS's Pay button, saved-card rows, bins,
"Use a new card" and server-field inputs answered to their container's name on
0.7.0), and iOS's device-language rung reads the shopper's own language list.
No Dart API change.

## 0.7.0

Additive in Dart. No existing call needs a change.

* `PayCross.configure` takes a `locale`, a BCP 47 tag such as `fr` or `fr-CA`
  that pins the language the native payment sheets draw in. Both SDKs now ship
  English and French. It applies to the sheet only; your app's own language is
  untouched.
* The language is the first of four candidates naming a language the SDKs
  ship: your `locale`, then the payment session's own `locale`, then the
  shopper's device languages, then English. Each is matched on its own — the
  whole tag, then its primary subtag, so `fr-CA` gets French — and one that
  matches nothing falls through to the next rather than ending the ladder. Null
  is that first rung left empty, not a request for English.
* The **amount** is not clamped to those two languages. It is formatted with
  the first *well-formed* locale anyone named, region intact, so a German
  shopper reads an English sheet over an amount written the way they expect. A
  malformed tag is passed over for the amount as well as for the words, so a
  typo cannot both pick the wrong language and misprint the price.
* This package passes the tag across exactly as written. It does not resolve,
  validate or normalise it: both native SDKs already do, and they skip a
  malformed tag rather than throwing on it, so nothing passed here can fail a
  payment.
* Every element the sheets draw carries a stable `paycross.*` test identifier,
  and it is the same string on both platforms. **On Android they reach a
  UiAutomator or Espresso tree only when the host app is debuggable**; on iOS
  they are set in every build. Three names — `paycross.brand`,
  `paycross.threeDSCancel` and `paycross.cancel` — are iOS-only, because
  Android draws no element behind them. The README says how to cancel from an
  Android test without one.
* Both sheets gained an accessibility floor: every control is named, a decline
  and a wait are announced, colour is never the only signal, and the text size
  a shopper set is honoured.
* Requires the native Android SDK at paycross-android 0.8.0, up from 0.7.0, and
  the native iOS SDK at PayCross 0.7.0, up from 0.6.0. Those releases carry the
  French strings, the resolution rule, the identifiers and the accessibility
  work above.
* The example app's Settings screen has a language setting — System, English or
  French — stored across launches and read once at launch, like the Google Pay
  merchant id beside it.

## 0.6.0

Additive in Dart. No existing call needs a change, and one parameter is
deprecated rather than removed.

* `PayCross.configure` takes a `PayCrossAppearance`, and it themes the native
  sheets on **both** platforms. It carries a `PayCrossColors` palette for light
  and one for dark — `brand`, `onBrand`, `surface`, `component`,
  `componentBorder`, `text`, `textSecondary`, `placeholder`, `icon`, `error` —
  a `PayCrossThemeMode` that pins the sheet to light or dark or follows the
  device, `PayCrossShapes` for corner radii and border width, a
  `PayCrossPrimaryButton` for the Pay button's colours, radius and height, and
  `PayCrossTypography` for a font scale. Every role is nullable, and null means
  "take the next source" rather than black.
* Colours resolve per role: what you set, then the brand colour set on the
  merchant account in the PayCross back office, then the platform default. The
  back-office colour arrives with the session, so **it themes both sheets with
  no code at all**. `onBrand` left null is derived from the brand's own
  luminance, so a light brand cannot end up with an unreadable white label.
* `PayCrossAppearance.brand(color)` sets one colour in both modes and leaves
  everything else alone.
* `brandColorArgb` is **deprecated** in favour of
  `appearance: PayCrossAppearance.brand(color)`. It still works, and it now
  applies on iOS as well as Android — the iOS SDK had no brand-colour hook when
  it was added, and now has one.

  Passing both does not lose the colour. If either palette names `brand`, the
  appearance wins outright; if neither does — an appearance that is only shapes
  or only a font scale, which is what a half-finished migration looks like —
  the legacy colour is merged into `brand` in both palettes. Either way it is
  not sent to the natives on its own, so neither has to decide which of two
  brand colours is the real one.

  Note that Dart does not report a deprecated *named parameter* at a call site,
  so nothing in your build will warn you. This entry and the README are the
  deprecation.
* `PayCrossColors.copyWith` and `PayCrossAppearance.copyWith`, for building a
  palette up in steps. Passing null keeps the value already there rather than
  clearing it; construct a fresh palette to unset a role.
* `PayCrossAppearance.hasBrand` answers whether either palette names a brand
  colour. It is the question the merge above asks, and it is public because it
  is also the question a merchant asks before deciding whether their own
  fallback is needed.
* `PayCrossErrorCode.invalidAppearance` is a new code. `configure` throws it,
  before anything reaches a native SDK, for a `sizeScaleFactor` outside 0.8–1.3
  or a negative or non-finite radius, border width or height. Both native SDKs
  clamp the scale instead, for callers that reach them directly; this package
  refuses, because a merchant who asked for 3.0 wanted something no sheet will
  draw.
* Layout, the card inputs' internals, the wallet buttons' colours and labels,
  the 3-D Secure page and the error copy are fixed by design and no appearance
  field reaches them. The wallet buttons' corner radius follows
  `shapes.buttonCornerRadius`, and that is the only property of theirs this SDK
  sets. A font family is not exposed in this release.
* Requires the native Android SDK at paycross-android 0.7.0, up from 0.6.0, and
  the native iOS SDK at PayCross 0.6.0, up from 0.5.0. Both add the appearance
  model above, and both fix live defects with it:
  * Android: text the sheet drew without an explicit colour was black in dark
    mode — the amount, the saved-card titles, the CVV prompt and more — and the
    Google Pay button kept Google's dark variant whatever the sheet's mode was,
    which is the wrong variant on a dark surface.
  * iOS: the Pay button drew its label and spinner in white whatever the accent
    colour was, so on a light accent the amount vanished on the one control the
    shopper has to press.
* The example app has an "Appearance" tile that runs an ordinary payment with a
  brand colour and the sheet pinned to dark, and puts the SDK back as it was
  when the run ends.

## 0.5.0

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
