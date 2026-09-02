# PayCross Demo

An internal QA app for the PayCross payment SDKs. Install it, type sandbox
merchant credentials into it once, and run payment scenarios on a real phone
without anybody minting a session token for you.

**It holds merchant credentials on your phone.** It is for colleagues, never
for merchants or anyone outside the company.

It has two environments. **Test** is the PayCross sandbox and is where
everything in this guide happens unless it says otherwise. **Live** is
production: real cards, real money, one scenario, and a red banner across
every screen of the app while you are in it. The app starts in Test on every
launch and the choice is never remembered. See [Live mode](#live-mode). Both
sets of endpoints are compile-time constants; they are in
[`lib/demo/endpoints.dart`](lib/demo/endpoints.dart).

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

Open the gear in the top right. At the top is the **environment switch** —
Test or Live — and under it a line naming the endpoint that environment will
use. In Test it is the sandbox, and everything below is as it always was.

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
"Sandbox — client " and the first six characters of the id. In Live it is a
different strip — "Live — no credentials this session", or "Live — client "
and six characters — and it has no secure store in reach at all: it can only
show what is in memory for this session.

## Home: the scenarios

This is what Home looks like in Test. In Live it has one tile and none of
what follows — see [Live mode](#live-mode).

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
same list is in the app under the card icon in the top bar — in Test; Live
hides that icon, because none of these PANs does anything on a production
merchant — and in
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

Four things to know:

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
- **In Live they do not work at all.** The app says *"Live mode — links are
  disabled"* and starts nothing.

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

## Live mode

Live mode runs **one** scenario against the PayCross production merchant with
a **real card**: a 1.00 charge, in a currency you pick, which you refund by
hand immediately afterwards. It exists so the mobile SDKs can be
smoke-tested against production before a release. It is not a QA tool and it
is not for routine use.

**The app starts in Test on every launch.** The environment is deliberately
never remembered, so the worst a forgotten toggle can cost you is one
relaunch.

### Getting in

1. Settings → the environment switch → **Live**. Nothing happens yet.
2. A field appears. Type `LIVE` — the word, in capitals. The switch button
   wakes up.
3. Press **Switch to Live**. A red `LIVE — REAL MONEY` bar appears across
   every screen and stays there until you leave.
4. Type the **production** client ID and secret, and the **name and
   email** the charge is made under, pick the currency, then press **Use
   for this session**.

### The credentials and the identity

**They are held in memory and written nowhere.** Not to the Keychain, not to
EncryptedSharedPreferences, not to History, not to a bug report. Closing the
app forgets them. Switching back to Test forgets them. There is no Save,
there is no Forget, and there is nothing on the device to leak — which is
also why you type them again every time.

What Live does *not* claim is that it never opens the secure store. Settings
still reads it on the way in, the same call it makes in Test, because that is
the screen you come back to. What Live changes is the two things that matter:
it never puts what it read on a Live screen, and it never writes to the store
while you are there. So a sandbox credential cannot appear in a Live field one
tap from a production round trip, and a production credential you type cannot
end up in the Keychain.

**The name and the email are typed here too, and held the same way.** They
are who the charge is made under: PayCross's own internal person, not
a sandbox fake. `john.doe@example.com` at a New York address is what the
sandbox presets send and what production fraud rules are built to refuse, so
a Live smoke never reuses them. Type a first and a last name — the create
schema needs both, so the name is split on the last space and a single word
is refused — and a real internal address, which is where the receipt goes.
**Use for this session** stays dead until all four fields are filled and the
address has an `@` in it.

**The currency is picked here too, and held the same way.** A dropdown over
EUR, USD and GBP, starting on EUR, beside the name and the email. It is what
the smoke charges in, because a production merchant may only be able to take
one of the three — and a smoke locked to euros on a pounds-only merchant
fails for a reason that says nothing about the SDK. The amount is one unit
either way: 1.00 is 100 minor units in all three. Like the identity, it is
held in memory for this session, written nowhere, and back to EUR the moment
you switch to Test.

**Nothing about the identity is saved either.** Not to the Keychain, not to
History, not to a bug report. The run is recorded by its ids and its
outcome, exactly as a sandbox run is. You type it again next session.

There is no **Verify credentials** in Live. The smoke charge is the
verification, and a probe would create a real production session as a side
effect of checking a password.

### Running the smoke

Home shows one tile: **Live smoke — €1.00 charge**, with the currency you
picked in place of the euro sign. No presets, no editor, no
Custom, no saved-card scenarios, no Google Pay, and no test-card cheat sheet in
the top bar — those PANs mean nothing on a production merchant.

With nothing held for this session the tile does not ask you anything —
it takes you to Settings. So the only way to reach the dialog is to have
already typed a production pair, a name and an email in this session. The
currency needs no typing: there is always one selected.

Once it can run, tapping it asks *"This will charge a real card €1.00.
Continue?"* — again with the currency you picked. Cancel is the default and
holds the focus, and dismissing the dialog — Android back button included —
counts as Cancel. Continue mints a production session and opens the native
sheet, and from there it is an
ordinary payment with an ordinary card. The red bar is **not** over that
sheet: it is a platform view this app does not draw, so at the one moment you
are typing a real card number, nothing on screen says LIVE.

**If you ever change the amount, it is one edit.** The constant
`liveSmokeMinorUnits` in [`lib/demo/live.dart`](lib/demo/live.dart) is the
figure, and `liveSmokeAmountLabel` beside it is the only place it is written
for a human to read. The four sites that quote it — the tile's title, the
tile's subtitle, the Live paragraph at the top of Home and the confirmation
dialog — all render that one function, so they cannot end up quoting two
different numbers to the person about to spend the money. Three of them used
to spell it out by hand.

### Afterwards — refund it

The result screen shows a red block with **an id and a copy button**, and what
to do about it. **This app cannot refund anything**; that is deliberate for a
tool used this rarely.

The block is on every Live run that got as far as an id, **including one the
bank refused**. It is not a signal that money moved — it is the id you need in
order to go and find out. Only the sentence changes:

- Approved, cancelled, timed out, or any other unresolved end: *"Refund this
  in the back office now."*
- Refused: *"Refused, so nothing should have been captured. Check the back
  office by this id before you assume it."*

If the run ended without a transaction id — you cancelled the sheet, it timed
out mid-poll, something threw — the block shows the **session id** instead and
says to search the back office by it. One of the two always exists, because
the session is minted before the sheet opens. If the *mint itself* failed
there is no id and also no charge, so there is nothing to refund and the error
message is the whole story.

The run lands in History marked **LIVE** in red, with the same ids and the
same bug-report block every other run gets.

### What Live mode will not do

- **Deep links are refused.** `paycross-flutter-demo://run` says *"Live
  mode — links are disabled"* on screen and does nothing else. A real charge
  goes through a confirmation dialog, and a link is exactly the shape that
  arrives without one.
- **The amount is fixed.** 1.00, hardcoded, no editor anywhere near it. The
  currency is a choice; the figure is not.
- **Nothing but the smoke.** No decline scenarios, no saved cards, no
  wallets. Apple Pay will slot in beside the smoke tile once the native iOS
  SDK ships it; it has not.

### Getting out

Settings → **Test**. Normally it happens at once: the credentials are dropped
and the banner goes. So does killing the app.

**An exit can half-fail, and then you are still in Live.** If the SDK refuses
to re-point, the credentials are dropped anyway — that half is unconditional —
but the environment does not flip, the red bar stays up, and Settings says
*"The credentials are forgotten, but the SDK would not switch back: … Still in
Live — restart the app."* Restart it. A relaunch always starts in Test.

## Known limitations

- **A run that fails to mint writes no History row**, and gets no "Copy bug
  report" button. Copy the on-screen message by hand; it never contains a
  credential.
- **The deep link only fires from Home** (above).
- **The automation build and this build are the same app id**, so they replace
  each other. Install one at a time.
- Tiles going dead is the only busy state. There is no progress indicator.
- **Live credentials are typed every session.** There is nowhere to save them
  and that is the design.
- **Live has no refund, no receipt and no spend tracking.** The transaction
  id and the back office are the whole workflow.
- **A Live run that never reaches the sheet still minted a session.** No
  charge, but a session exists on production; it expires on its own.

## The automation build

Built with `--dart-define=PAYCROSS_E2E=true`, the app shows the frozen
paste-token screen instead of Home. That build reads no stored credentials,
registers no deep-link handler, and never sees the environment switch at all —
automation always runs Test. It exists for the E2E matrix runner in
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
