# PayCross Demo

An internal QA app for the PayCross **TEST sandbox**. Install it, type TEST
merchant credentials into it once, and run payment scenarios on a real phone
without anybody minting a session token for you.

**It holds TEST M2M credentials on your phone.** It is for colleagues, never
for merchants or anyone outside the company, and it has no way to reach
production — the endpoints are compile-time constants and there is no
environment switch. See [`lib/demo/endpoints.dart`](lib/demo/endpoints.dart).

## Install

### Android

`adb install` is the supported route.

1. Get `paycross-demo.apk`. It is attached to the private GitHub Release on
   `paycross/paycross-flutter` once the release pipeline lands (Plan 3b);
   until then, ask whoever built it, or build it yourself — see
   [Building from source](#building-from-source).
2. If you have an older build of this app, uninstall it first. The app id
   changed, so the new build installs **beside** the old one rather than
   replacing it:

   ```
   adb uninstall com.paycross.paycross_flutter_example
   ```

3. Install:

   ```
   adb install -r paycross-demo.apk
   ```

Why not just tap the APK on the phone: from 2026-09-30 in Brazil, Indonesia,
Singapore and Thailand — globally in 2027 — Android developer verification
makes a tap-to-install of an unregistered developer's APK cost the installer
Developer Mode plus a 24-hour wait. `adb install` is exempt from it.
Registering this package under a verification account is an owner follow-up
that has not happened.

The app id on both platforms is `com.paycross.flutterdemo`. The native Android
demo (`com.paycross.demo`) is a different app and the two coexist.

### iOS

TestFlight, group **PayCross Demo — Internal**. That comes with Plan 3b; there
is no iOS build to install yet.

## First run: Settings

Open the gear in the top right. The screen says "Sandbox only" and shows the
endpoint it will use.

1. **Client ID** and **Client secret** — TEST M2M credentials. Get them from
   the team. They are not in this repo and must never be written into it.
2. **Google Pay merchant id (Android, optional)** — leave it empty unless you
   are testing the wallet button. It is read **once at launch**, so restart
   the app after changing it.
3. **Save.** The pair goes into the platform secure store — Keychain on iOS,
   EncryptedSharedPreferences on Android.
4. **Verify credentials.** This mints one throwaway sandbox session and
   abandons it. It is the only proof that the credentials actually work.

**Verify does not save.** It mints with what is on screen, not with what is
stored. If the two differ it says so: *"Verified — press Save to keep them."*
Edit a field, verify, walk away, and you have proven a credential the next
launch will not use.

**Forget credentials** wipes all three — client ID, client secret and Google
Pay merchant id — from the secure store.

Home's top strip tells you where you stand: "Sandbox — not configured", or
"Sandbox — client " and the first six characters of the id.

## Home: the scenarios

Tap a tile to run it. Each tile carries what should happen and which card to
type. The pencil on the right opens the raw session body first, so you can
change an amount or a field and run that instead.

| Preset | What it proves |
|---|---|
| Instant approve (no 3DS) | The happy path with no 3-D Secure step at all. |
| Frictionless 3DS | 3-D Secure that clears without asking the shopper anything. |
| 3DS challenge → approve | The full challenge, approved on the sandbox ACS page. |
| 3DS challenge → decline | A terminal refusal after the challenge (recovery `do_not_retry`). |
| 3DS challenge → retryable decline | A retryable recovery: the sheet **re-arms** for another attempt instead of returning. Cancel it to come back. |
| Store card (COF) | Saving a card for later, against the fixed customer `harness_cof_customer`. Safe to re-run. |
| Pay with saved card (COF) | Charging that stored card without retyping it. **Run "Store card (COF)" first**, or the card list is empty. |
| Google Pay (Android) | Whether the TEST merchant has the wallet enabled. Eligibility is merchant configuration, not a per-session setting, so the button's absence is not a bug. |
| Custom | Opens the editor on the ordinary body. Whatever you make it do. |

While a run is being set up the tiles go dead. That is the only busy
indicator; there is no spinner.

## Test cards

Every card below: expiry **12/28**, CVV **123**, cardholder **John Doe**. The
same list is in the app under the card icon in the top bar, and in
[`lib/demo/test_cards.dart`](lib/demo/test_cards.dart).

| PAN | What it does |
|---|---|
| 4111 1111 1117 0000 | Approve, no 3-D Secure |
| 4111 1111 1115 3063 | Frictionless 3-D Secure |
| 4111 1111 1115 3220 | 3-D Secure challenge |
| 4111 1111 1115 0002 | Decline: `do_not_honor` |
| 4111 1111 1115 9995 | Decline: `insufficient_funds` |
| 4111 1111 1115 0119 | Decline: `fraud_suspected` |
| 4111 1111 1115 0051 | Provider timeout |

For the challenge card, **the ACS page decides the outcome, not the PAN**: tap
approve, `authentication_failed`, `do_not_honor`, `fraud_suspected` and so on
on the sandbox challenge page.

### Do not use these three

| PAN | It used to be | What it actually does |
|---|---|---|
| 4111 1111 1115 3055 | Challenge, then decline | **Approves.** No 3-D Secure at all. |
| 4111 1111 1115 0069 | Decline `card_expired` | **Approves.** |
| 4111 1111 1115 0127 | Decline `invalid_cvv` | **Approves.** |

The TEST sandbox does not route them, and an unrouted PAN defaults to approve.
They appear in older harnesses and in the native Android demo's seed list, so
somebody always tries one, watches a "decline" succeed, and files an SDK bug.
It is not an SDK bug — it is `io.paycross#870`. Reach `card_expired` and
`invalid_cvv` through the challenge card's ACS page instead.

## Running a scenario from the command line

```
adb shell am start -a android.intent.action.VIEW \
  -d "paycross-flutter-demo://run?preset=3ds-challenge-approve&surface=sheet"
```

`preset=` takes either the slug (lower case, everything else collapsed to `-`)
or the preset's exact name percent-encoded. `surface=sheet` is the only
surface this app has.

Three things to know:

- **It only works from Home.** With Settings, History, the cheat sheet, the
  editor or a previous run open, the app says *"Link ignored — close the open
  screen first."* Back out to Home and fire it again. This is deliberate:
  pulling an open screen out from under you would be worse.
- The link is delivered to the app that is already running (warm start), and
  exactly one app answers this scheme — the native Android demo owns
  `paycross-demo://`, which is a different one.
- A link carries a preset name and nothing else. It cannot carry a credential,
  a token or a body, so one left in your shell history says only which
  scenario you ran.

## History, and reporting a problem

Every run that reaches the payment sheet lands in **History** (the clock icon).
Tap a run and its bug report is on your clipboard. The Run screen has the same
button, **Copy bug report**, once the run has settled.

The block holds when, which scenario, the session id, the transaction id, the
outcome, and the demo/plugin/native SDK versions. **It carries no token and no
credential by construction** — the type it is built from has no field that
could hold one — so it is safe to paste anywhere an issue is safe.

File it as a GitHub issue with the label `merchant-readiness`, on the repo
that owns the problem:

- `paycross-flutter` — the Flutter plugin, or this demo app itself.
- `payment-android-sdk` / `payment-ios-sdk` — something the native SDK did on
  that one platform.
- `io.paycross` — a sandbox or backend gap, like a card that does not route.

Paste the bug report block, say what you expected, and say what you saw.

## Known limitations

- **A run that fails to mint writes no History row**, and gets no "Copy bug
  report" button. Copy the on-screen message by hand; it never contains a
  credential.
- **The deep link only fires from Home** (above).
- **The automation build and this build are the same app id**, so they replace
  each other. Install one at a time.
- Tiles going dead is the only busy state. There is no progress indicator.

## The automation build

Built with `--dart-define=PAYCROSS_E2E=true`, the app shows the frozen
paste-token screen instead of Home. That build reads no stored credentials and
registers no deep-link handler; it exists for the E2E matrix runner in
`tool/e2e/`, and it is **not** what a colleague installs.

If you are changing this app: do not touch
[`lib/e2e_label.dart`](lib/e2e_label.dart) or
[`lib/automation_screen.dart`](lib/automation_screen.dart). They are the
runner's contract, and a test greps `lib/` to keep label strings from being
written anywhere else.

## Building from source

You need Flutter **3.44.2 or newer**. From `example/`, `flutter build apk
--debug` produces `build/app/outputs/flutter-apk/app-debug.apk`. Android
compiles against SDK 37 (`flutter_secure_storage` 11 requires it), so
`platforms;android-37` must be installed. iOS builds on macOS need
`DEVELOPER_DIR` pointing at Xcode — and until the Mac's `xcode-select` is
repointed away from the Command Line Tools, they also need the `xcrun` shim on
`PATH`, because Flutter's native-assets hook does not pass `DEVELOPER_DIR`
through to the hook process.

---

Integrating the plugin in your own app is a different job: the whole
integration is [`lib/main.dart`](lib/main.dart) plus the
[package README](../README.md).
