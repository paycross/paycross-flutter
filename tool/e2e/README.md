# E2E matrix runner

Drives the example app through real payments against the PayCross **TEST**
sandbox — on an Android emulator and on an iOS simulator — and judges every
attempt against the merchant API rather than against the screen alone.

A cell file declares one payment attempt: a card, a session, an ordered list of
actions and everything that has to be true afterwards. The runner mints a
sandbox session, hands the token to the example app, replays the actions through
a platform driver, reads the outcome label out of the accessibility tree,
cross-checks the merchant API, scans the device log for crashes, and writes
redacted evidence.

This directory contains no credentials and no hostnames beyond the TEST API
named in the env file you pass at runtime.

## Quick start

Install the dependency (PyYAML; everything else is the standard library):

```bash
pip install -r tool/e2e/requirements.txt
```

To run what CI runs — pytest and ruff, both pinned exactly, because a floating
linter turns a clean tree red on the day it gains a rule:

```bash
pip install -r tool/e2e/requirements-dev.txt
ruff check  --config tool/e2e/ruff.toml tool/e2e
ruff format --check --config tool/e2e/ruff.toml tool/e2e
```

Every command below is run from the repository root.

### Android

Build the example with the automation define, then run:

```bash
(cd example && flutter build apk --debug --dart-define=PAYCROSS_E2E=true)

python -m tool.e2e.runner \
    --platform android \
    --cells tool/e2e/cells/d0 \
    --evidence-root ~/e2e-evidence/d0-debug \
    --env-file ~/path/to/.env.staging \
    --app example/build/app/outputs/flutter-apk/app-debug.apk
```

### iOS

The `.app` is built **on the Mac** — the simulator, Xcode and WebDriverAgent all
live there — and `--app` takes the Mac-side path. The runner itself still runs
in WSL and reaches the Mac over `ssh mac`:

```bash
# on the Mac, in the example directory
flutter build ios --simulator --debug --dart-define=PAYCROSS_E2E=true

# in WSL
python -m tool.e2e.runner \
    --platform ios \
    --cells tool/e2e/cells/d0 \
    --evidence-root ~/e2e-evidence/d0-debug \
    --env-file ~/path/to/.env.staging \
    --app /Users/<you>/…/example/build/ios/iphonesimulator/Runner.app
```

### Release builds

A debug build proves nothing about a shipped one. The example's `release` build
type turns on R8 and resource shrinking — `isMinifyEnabled` and
`isShrinkResources` in `example/android/app/build.gradle.kts` — because the
Android SDK returns its outcome across an `Intent` and only its own
`consumer-rules.pro` keeps `PayCrossResult`, its subclasses and `Recovery` from
being renamed. If those rules ever stop being applied, every payment comes back
as `error:resultUnknown` instead of its real outcome, and nothing but a minified
build can show it.

`example/android/app/proguard-rules.pro` is deliberately empty: the rules this
build needs come from the libraries. A rule appearing there means the SDK is not
shipping one it should, which is a finding to file rather than a line to add.

```bash
(cd example && flutter build apk --release --dart-define=PAYCROSS_E2E=true)

python -m tool.e2e.runner \
    --platform android \
    --cells tool/e2e/cells/d0 \
    --evidence-root ~/e2e-evidence/d1-release-android \
    --env-file ~/path/to/.env.staging \
    --build-id "android-0.3.3-release-r8" \
    --app example/build/app/outputs/flutter-apk/app-release.apk
```

A **fresh evidence root and a distinct `--build-id`**: a pass recorded against
the debug build is not this build's. `--app` implies `--all`, which is the same
answer without having to name a build, but naming it is what makes the evidence
say which build passed.

The keep rules are checkable statically as well. Beside `mapping.txt` sits
`configuration.txt`, which records every rule file R8 consumed, and the SDK's
consumer rules appear in it verbatim — lines 118-131 of the run this section
documents, under `paycross-android-0.3.3/proguard.txt`. `mapping.txt` then
shows the effect: the classes that cross the `Intent` map to *themselves* while
everything around them is renamed. That is evidence the rules were applied; the
live run is the evidence they were enough.

**iOS is build-only, and cannot be otherwise.** Flutter refuses any non-debug
build for the iOS simulator — `BuildInfo.supportsSimulator` is
`isEmulatorBuildMode(mode)`, which is `mode == BuildMode.debug`, and
`build_ios.dart` turns anything else into `'<MODE> mode is not supported for
simulators.'` So the D0 set can only ever execute against a debug iOS binary,
and what a release build can prove there is that it compiles and links:

```bash
# on the Mac, in the example directory
flutter build ios --config-only --release --no-codesign
(cd ios && pod install)
flutter build ios --release --no-codesign --dart-define=PAYCROSS_E2E=true
```

`--no-codesign` is needed on `--config-only` too when the machine has no signing
identity; without it that step fails before `pod install` with *"No development
certificates available to code sign app for device deployment"*. Check that
`Runner.app/Frameworks` holds `PayCross.framework` and `PayCrossCore.framework`
and that `otool -L Runner.app/Runner` links both. Closing the gap for real needs
a physical device through TestFlight.

The two build ids in use are `android-0.3.3-release-r8` and, if a device run
ever becomes possible, `ios-0.1.1-release`.

### Flags

| Flag | Meaning |
|---|---|
| `--platform` | `android` or `ios`. Required. |
| `--cells` | a directory of cell files. Required. |
| `--evidence-root` | where proof is written. Required. Outside any git checkout, and **one root per dimension** — see below. |
| `--env-file` | shell-style file holding the five sandbox keys. Required. |
| `--all` | rerun cells that already passed under this evidence root |
| `--app` | APK (Android) or a `.app` **on the Mac** (iOS) to install first. Implies `--all`. Omit to use what is already installed. |
| `--build-id` | names the build under test, e.g. `android-0.3.3-release-r8`. Written into every progress record; a resume only trusts a pass whose build-id matches. |
| `--only` | run just this cell; repeatable |

A run executes every `*.yaml` in `--cells` that declares this platform, in
**filename order**. The glob is not recursive, so point it at a dimension
directory such as `cells/d0` rather than at `cells/`. Filename order is the
only ordering there is — a pair of cells that must run in sequence, such as
D5's save-then-reuse, is ordered by naming them so.

A rerun **skips what already passed** under the same evidence root, so an
interrupted matrix is resumed rather than restarted.

Two things bound what a resume may trust, and they are handled differently.

* **The build** is carried. `--build-id` names it — hashing is not an option,
  since the iOS `.app` is a directory on the Mac — and a pass recorded under one
  name never satisfies a run under another. A run that names no build matches
  records that carry none, which is every record written before this existed, so
  an older evidence root keeps resuming exactly as it did. `--app` still implies
  `--all`, which is the same answer without having to name a build.
* **The dimension** is discipline. `passed_cells` keys on the cell id alone and
  every dimension directory contains a cell called `control`, so a shared root
  would let D0's `control` pass satisfy D2's. Use
  `--evidence-root <root>/<dimension>-<variant>-<platform>`.

The env file must define `CLIENT_PAYX_SANDBOX_ID`, `CLIENT_PAYX_SANDBOX_SECRET`,
`TOKEN_URL`, `PAYMENT_API_URL` and `PAYCROSS_VERSION`. It is parsed for exactly
those five keys rather than sourced, so nothing else in it can reach a
subprocess by accident, and the values stay inside one `Sandbox` instance.
Nothing here prints them.

The example app must be built with `--dart-define=PAYCROSS_E2E=true`. That is
what makes it render the contract labels the runner reads. `bool.fromEnvironment`
accepts the literal string `true` and nothing else — `PAYCROSS_E2E=1` leaves the
contract off, and the run then times out waiting for a label that will never
appear.

## Exit codes

A nightly reads these rather than the output.

| Code | Meaning |
|---|---|
| `0` | every cell passed, or was skipped as already passed |
| `1` | a cell failed, or the run itself had a problem |
| `2` | a setup or cell-authoring mistake; nothing ran |
| `3` | **ABORTED** — the rig or the backend is broken |

The run ends with one summary line:

```
6 cells, 6 passed, 0 failed, 0 skipped, 0 control checks, aborted: no
```

`skipped` counts cells a resume did not rerun; `control checks` counts
interleaved controls, which are not cells and are not in the other totals.

## The skepticism rule

A failed cell is not believed on its own. The runner immediately reruns the
`control` cell — the plain no-3DS approval — and only a control that passes lets
the failure stand as a finding. **Two consecutive control failures abort the
run** with exit 3.

An abort prints its banner *first*, before any result line, and every failed
non-control cell above it is tagged `(unverified)`. Believe nothing so tagged:
a broken rig otherwise produces a page of findings that are all the same
finding. This is not theoretical — it is what caught a mid-run bearer expiry on
2026-08-29 that would otherwise have read as four SDK defects.

Because of that rule, **every dimension's cell directory must contain its own
`control` cell that runs on the platform being tested**. A directory without one
is refused before a credential is read (exit 2). Do not share one across
dimensions, and do not share an evidence root either: `passed_cells` keys on the
cell id alone, so D0's `control` pass would otherwise satisfy D2's resume.

`tool/e2e/tests/cell_rules.py` holds the authoring rules every dimension's
directory must satisfy — a control cell, a terminal verb last (teardown aside),
no PAN that approves on TEST, `no_succeeded_txn` pinned to a session that
exists, no airplane mode on iOS, every rig setting a cell turns on turned off
again, and no bare `wait` outside the expiry recipes. A new dimension's test
file calls `check_cell_dir` rather than restating them.

### Pass criteria

1. the label matches the cell's expectation, and a non-empty `<txn>` names a
   transaction the session really has;
2. the merchant API agrees on every key the cell asserts;
3. no crash, ANR or uncaught exception in the device log for the cell's window.

#### The one line a cell may be excused

`always_finish_activities 1` makes the activity manager log `Force finishing
activity <package>/…` for the app under test **by design** — it is literally
what the setting does, and it is the behaviour the `dont_keep_activities` cell
exists to observe. Criterion 3 counts that as a fault, so before this the cell
failed however the plugin behaved while its interleaved control passed: the
exact shape of a false finding. The package filter does not help, because those
lines genuinely name the app.

A cell may therefore declare it:

```yaml
tolerated_crash_markers:
  - "Force finishing activity"
```

Three things bound that, and they are the point:

* **The list is closed and validated at load.** `cells.TOLERABLE_CRASH_MARKERS`
  holds exactly one marker. `FATAL EXCEPTION`, `ANR in` and the Dart and Swift
  markers are not in it and must never be — a cell that could mute those could
  pass a crash through, which is the one thing criterion 3 exists to stop.
* **`verify.crash_lines` honours only that list, whatever it is handed**, and
  can excuse only from the scoped-fault branch. No caller — not just no cell
  file — can talk it into muting a real crash.
* **Nothing is muted, only reclassified.** The excused lines are written into
  `result.json` as `tolerated_crash_lines`, beside the declared
  `tolerated_crash_markers`. For that cell they *are* the observation it was
  written to make, and an empty list where a marker was declared says the
  behaviour did not happen — which is a finding of its own.

### Budgets

Each cell gets a budget derived from its actions. It is a **hang backstop, not
a performance assertion**: it is checked between steps, never
interrupts a driver call in progress, and a cell that finishes inside it has
proved nothing about how quickly it did so. The same goes for the `wait_result`
seconds in a cell file — they bound a hang, they do not describe expected
latency.

The budget is measured on the **monotonic** clock, which cannot see a host
suspend — and a suspend always lands *inside* a driver call, because that is
where the process spends its time, while the budget is only checked *between*
steps. So each cell also compares wall-clock elapsed against monotonic
elapsed. They agree to within scheduling noise while the machine is awake and
diverge by exactly the suspend when it is not; a divergence over a minute is
recorded as `host_suspended_seconds` and fails the cell saying so.

That is not defensive. Measured 2026-08-31: WSL slept for six and a half hours
with two runs in flight, `timeout` never fired because its alarm is monotonic
too, and both runs froze mid-cell and thawed against sessions minted before
the sleep. The cost was not the lost time but the **misdiagnosis** — the cell
failed with `the sandbox ACS page never appeared within 120s`, which reads as
a sandbox fault, and the only clue was `seconds: 23963` against
`budget_seconds: 1446` in a field nothing asserted on.

## Cell files

```yaml
id: challenge_approve           # must equal the filename stem
platforms: [android, ios]       # non-empty; android and/or ios
card:
  pan: "4111111111153220"       # 12-19 digits. QUOTE IT: an unquoted PAN with a
  expiry: "12/28"               #   leading zero is YAML octal.
  cvv: "123"                    # 3-4 digits
  holder: "John Doe"            # optional, defaults to "John Doe"
session:
  amount: 1000                  # positive integer, minor units
  currency: EUR                 # upper-case ISO 4217
  options: {}                   # optional; DEEP-merged over the default mint
                                #   body, so pinning customer.merchant_reference
                                #   keeps the rest of the customer block
actions:
  - paste_token
  - type_card
  - tap_pay
  - acs:approve
  - wait_result 180
expected:
  label: "result:success:<txn>"   # a literal, or `<any>` / `<none>` -- see below
  rearmed: false                # optional, defaults to false
  merchant:
    session_status: completed
    txn_count: 1
    txn_status: succeeded
    threeds:
      outcome: authenticated
      flow: challenge
      liability_shifted: true

# Optional, and HYPOTHETICAL -- shown for the grammar, not because any shipped
# cell needs it. No D0 cell carries an override: both platforms return
# change_method for authentication_failed, which is what the live runs measured.
# Merged one key deep over `expected`; `merchant` is merged key by key, so an
# override restates only the field that actually differs. No D2 cell carries
# one either: where its platforms may diverge it records the label per
# platform with `<any>` rather than asserting two different ones. Phase 3 is
# where an override lands, once a live run has shown one is needed.
expected.ios:
  merchant:
    failure_recovery: retry
```

Everything a cell can say is validated at load time — verbs, their arguments,
the label, every merchant key and value, and the `threeds` block's inner keys —
so a typo fails in seconds rather than being read as an SDK finding twenty
minutes into a matrix run. Cell files are also validated in CI.

Two cross-field rules are checked at load as well, **over every platform the
cell declares** rather than over the unmerged base: a platform expecting a
re-armed sheet must have an `expect rearmed` action to look with, and the action
must not be there unless *every* platform expects one — the action list is
shared, so it runs on the other platform too and answers falsy. The same pair
holds for `<none>` and `expect no_result`. A cell whose `expected.android`
alone expects a re-arm used to load cleanly and fail on a device twenty minutes
later.

### Label sentinels

`expected.label` is normally a literal in the frozen vocabulary, in which
`<txn>` is a capture (and a template carrying two of them is refused, because
the capture would be ambiguous). Two sentinels stand in for a literal:

| Sentinel | Meaning |
|---|---|
| `<any>` | any well-formed contract label, whatever it turns out to be. A **discovery** cell: it asserts a terminal outcome, exactly once, with no crash, and nothing about which one. The label it measured is recorded in `result.json` rather than compared. |
| `<none>` | no label may appear. For the process-kill cell, where the pending Dart call dies with the isolate and no result is delivered **by design**, so "the app said nothing" is the pass. Requires an `expect no_result` action. |

A cell carrying either sentinel still has to **pin the session** — `cell_rules`
demands `session_status` or `txn_count`. It cannot honestly promise
`no_succeeded_txn`, because whether money moved is part of what it is
measuring; what it must not be allowed to do is assert nothing at all, which
would pass on a device that did nothing at all.

`<any>` **captures the transaction id and records it.** It did not used to,
and because it captured nothing the id reaching `verify_label_transaction` was
always `None`, so that check returned on its first line and any discovery cell
could report an id naming nothing and still pass. Two D2 cells did exactly
that. The cross-check now runs either way; for a pinned label a mismatch is a
**problem**, and for a sentinel it is a **note** in `result.json`
(`label_transaction_notes`) — recording rather than asserting, because a
discovery cell named no label to be held to. The corollary matters when Phase 3
pins these: a cell whose id does not check out **cannot** be pinned to
`result:…:<txn>`, because the pin fails the very check `<any>` only recorded.

### Merchant assertions

`session_status`, `txn_count`, `txn_status`, `no_succeeded_txn`,
`failure_recovery`, `failure_code`, `network_decline_code`, `saved_card_saved`,
`saved_card_used`, `threeds`.

A key that is **absent is not asserted**. A key present with an explicit
**null** value asserts the field is absent — the two are different, and the
distinction is what `failure_recovery: null` is for.

Things worth knowing before you write an expectation:

* `no_succeeded_txn` reads **both** ways. `true` fails a session holding a
  transaction that moved money; `false` fails one holding none. And "moved
  money" is `succeeded`, `authorized` **or** `captured` — an `auth` session
  stops at the second and an `auth_capture` at the third, so a cancel cell
  looking only for `succeeded` would have passed on either.
* `failure_code` and `network_decline_code` read `transactions[-1].failure`,
  beside `failure_recovery`.
* `saved_card_saved` / `saved_card_used` assert **presence**, never a value.
  Both keys are on the scrubber's list, so what the verifier sees has already
  been through `evidence.scrub_resource` — and these work only because a
  scrubbed token is **replaced rather than removed**: the key survives carrying
  the redaction marker for a card that was stored, and is still `null` for one
  that was not. Removing the key instead, which reads like the safer choice,
  would turn every `saved_card_saved: true` into a failure; a test in
  `test_verify` pins the pair together for that reason.
* `threeds` accepts exactly `outcome`, `flow` and `liability_shifted`, and an
  unknown inner key is refused at load. `threeds.eci` and `threeds.version` are
  deliberately not assertable: a sandbox upgrade must not present as a finding.

### Actions

| Action | What it does |
|---|---|
| `paste_token` | enters the session token and taps the **example app's** Pay, then waits for the sheet |
| `present_token` | the same, **without** waiting for a sheet — see below |
| `tap_example_pay` | taps the example app's own Pay, with no token entry before it |
| `type_card` | fills the SDK's card form through the real fields |
| `tap_pay` | taps the **sheet's** Pay button |
| `acs:<outcome>` | waits for the sandbox ACS page and taps one outcome button |
| `cancel_challenge` | abandons an in-flight challenge and confirms |
| `cancel_form` | abandons the sheet from the card form and confirms |
| `expect <what>` | observes a non-result — see the table below |
| `wait_result <s>` | waits up to `<s>` for a contract label |
| `wait <s>` | spends `<s>` and does nothing else — see below |
| `wait_expired <s>` | waits up to `<s>` for a session to pass its own expiry, refreshing the cell's token on every poll |
| `enter_token <literal>` | types a literal into the token field, for the malformed-token cells |
| `relaunch` | cold-starts the app mid-cell. On iOS this keeps the console window the cell has already written; `launch` would truncate it |
| `airplane on\|off` | cuts the device's network and reads the setting back. **Android only** |
| `tap_google_pay` | taps the wallet button, by bounds — see below. **Android only** (D4) |
| `type_cvv` | types the cell's CVV into the CVV field and nothing else (D5) |
| `save_card` | makes sure the save-card box is ticked, and reads the state back to prove it (D5) |
| `select_saved_card` | chooses the first stored card, and verifies the form switched (D5) |
| `background <s>` | home screen, wait `<s>`, resume the **existing** task — never a fresh launch (D3) |
| `rotate` | a quarter turn, and it stays turned — a cell must turn back (D3) |
| `kill_activity` | ends the app's process, sheet and all — the stand-in for a low-memory kill (D3) |
| `dont_keep_activities on\|off` | the developer option, read back after writing. **Android only** (D3) |

Each `expect` argument has its own deadline, and a falsy answer fails the cell
naming the expectation and the number the wait really used:

| `expect` | Waits for | Deadline |
|---|---|---|
| `rearmed` | `tree.sheet_rearmed` — the sheet took a failure and offered the form again | 30 s |
| `no_result` | nothing to appear. Hands back the label that did, if one does | 60 s |
| `acs` | the sandbox ACS page, **without** tapping an outcome | 120 s |
| `google_pay` | the wallet button (D4) | 30 s |
| `no_google_pay` | no wallet button. Waited **out**, not for | 20 s |
| `saved_card` | a stored card on the sheet (D5) | 30 s |

**The Google Pay button's handle belongs to Google.** `tap_google_pay`,
`expect google_pay` and `expect no_google_pay` all match
`content-desc="Pay with GPay"`, which is drawn by Play services rather than by
the SDK — so it moves with the **GMS version** and with the **device locale**,
and it can break without a line changing in either repo. The SDK does tag its
own button (`Modifier.testTag("google_pay_button")`), but
`testTagsAsResourceId` is set nowhere in either repo, so Compose test tags are
invisible to `uiautomator`; that is filed as **payment-android-sdk#26**, and
until it lands this is the only handle there is. The node is also **not
clickable** — the click handler lives on the `AndroidView`, not on a Compose
node — so it is tapped at its bounds centre.

`expect no_google_pay` is the one expectation that waits its answer **out**
rather than waiting for it. Readiness is a `LaunchedEffect` that runs after the
session loads and after an asynchronous `isReadyToPay`, so a button that is
merely late would satisfy a single look — and the expectation would then pass
on every session, which is the one thing it must never do.

`paste_token` and `present_token` differ in one thing, and it matters. Both
enter the minted token and tap the example's Pay; **`paste_token` then waits for
the sheet and `present_token` does not.** Use `present_token` where no sheet is
the expected answer: on iOS a malformed or expired token is refused before
`present` is ever called, so waiting for a sheet costs a 60-second timeout and
then reports the wrong failure.

**Every verb in both tables above is now executable**, and every expectation
too: D3 landed the four lifecycle verbs and D4/D5 the wallet and saved-card
ones. The vocabulary is still opened a dimension at a time so cell files can be
written against a stable list; the dimension that owns a verb writes the driver
method, and every verb already reaches a `_perform` branch that calls it. Where
a method has NOT landed, the declaration on `Driver` raises
`NotImplementedError` and a cell using it fails as an **authoring mistake**
rather than a device fault — so no control check is spent proving a rig that was
never in doubt. That distinction is the whole reason the declarations exist: a
missing attribute would raise `AttributeError`, which the runner reads as a
broken device, and two of those in a row abort the run.

Two refusals are permanent rather than pending, and each says so: `airplane` and
`dont_keep_activities` on iOS.

A verb outside the grammar, or an argument the verb does not take, is a
different failure and stays a device-side `DriverError`: `load_cell` refuses
both, so no cell file can produce one.

An argument is written `verb:arg` or `verb arg`, and the two are
interchangeable: the parser splits on whichever delimiter comes first, so
`wait_result 1:20` is reported against `wait_result` — the verb that takes the
argument — rather than as an unknown action.

`enter_token`'s literal is capped at 200 characters and restricted to
`A-Z a-z 0-9 . _ ~ -`. The cap is far below the ~1011 of a real session token,
so a live credential cannot be committed in a cell file even by accident; the
character class is narrow because Android hands the value to `input text` on a
device shell that re-splits and expands whatever it is given, and a mangled
literal would leave the cell measuring a string it never sent.

**The challenge page is recognised by `ACS_MARKERS`, not by one title, and
that is a scar rather than a design.** `payment-sandbox` 687bf4e redesigned the
page, replacing `<strong>Sandbox 3DS Challenge</strong>` with a
`<div class="sandbox-badge">Sandbox</div>`; the old phrase survives only in
`<title>`, which never reaches an accessibility tree because a WebView exposes
rendered DOM text and not the document title. That commit is dated
**2026-04-13**: what happened mid-campaign was the TEST deployment *catching up*
to a four-month-old commit, not a redesign landing — which is worse, because a
rig cannot see which build is deployed, and reading `main` would have shown this
markup all along while the rig passed against an older deployed page. The page
carried the old text at 22:07Z and did not at 11:41Z the next morning, and
every android cell waiting
for a challenge failed in between while the frictionless control passed five
times interleaved with them. iOS was untouched, because it matches
`threeDSCancel`, an accessibility identifier on the SDK's own cancel bar,
rather than page text.

Two lessons are baked into that constant. **Match text the page renders**, and
**keep the old marker as well as the new one**, because deployments lag and a
detector that knows only the current wording breaks every rig still serving the
previous page.

`acs:<outcome>` must match the sandbox ACS button's text **verbatim** — the
outcome is chosen by which button is tapped, not by the PAN. It is checked
against the buttons the sandbox actually renders (`cells.ACS_OUTCOMES`), so a
typo is refused at load rather than after the 120-second page wait it used to
cost. That list is all three of the sandbox's button groups —
`authOutcomes`, `issuerOutcomes` **and** `technicalOutcomes`, which
`challenge.html.tmpl` renders alike, each button's visible text being the token
— and it is a literal here because the runner has no access to the Go repo. A
sandbox that adds a button is a one-line change; one that removes a button
shows up as a live cell failing rather than as a false pass. Use `expect acs`
where the cell has to see the page and then leave it alone.

`wait` exists for exactly one recipe and it is not slowness. A session token's
JWT `exp` is mint + 900 s while the session's own `expires_at` is mint + 1200 s
(`session_ttl` + `session_grace_period`), so the only way to present a token
that is expired while its session is still open is to wait out the difference.
`cell_rules` refuses it in any cell whose id does not name an expiry.

### Saved cards, which are two cells and not one

Card-on-file is the only dimension whose cells are **not independent**, and
getting that wrong is silent rather than loud. Three facts drive the shape:

* `customer.merchant_reference` identifies the customer. Omit it and the
  backend mints a random UUID, so the card is stored against a customer nothing
  will ever look up again.
* `saved_cards: {show: all}` is what puts the customer's cards into the session
  at all. Omit it and the list comes back empty however many cards exist.
* That list is snapshotted **once at session creation and never rebuilt**. So
  the paying session has to be minted *after* the storing one has settled —
  which, since filename order is the only ordering, means naming the pair
  `..._1_save` / `..._2_pay`.

And `save_card_config` on the request only *renders* the checkbox. The save is
driven by `card.save` on the submit, which in the SDK is the shopper ticking it
— hence the `save_card` action. A cell with the config and no action is an
ordinary payment asserting a save that never happened.

Two customer references rather than one, where a dimension has two pairs: each
selector then offers exactly one row, so "the first stored card" is never
ambiguous. Re-running a pair is safe — storing the same PAN again answers
`save_operation: already_existing`, so the customer accumulates exactly one card
however many times it runs, and `saved_card_saved` still passes because it reads
presence rather than the operation.

**The merchant API cannot answer "was a card offered".** `Sandbox.read` has no
`saved_cards` key under any condition; that list lives only in the public
checkout snapshot the SDK reads. So the question is answerable only from the
device, which is what `expect saved_card` is for.

Two platform differences the drivers hide, both measured rather than assumed:

* **What is tappable is not what is nameable.** Android's save checkbox has an
  empty `text` and an empty `content-desc`, so it is found by its `checkable`
  state; its label is a separate node that does nothing when tapped. On iOS the
  row carries the label but only the unnamed control inside it responds.
* **iOS scrolls, Android does not.** The iOS toggle sits below the fold, so
  `save_card` scrolls to it — and scrolls back, because a form left scrolled
  puts `amount` under the navigation bar and breaks the keyboard-dismissal
  fallback that `acs()` depends on. That is why `save_card` runs **before**
  `type_card` in every store cell: typing raises a numeric pad nothing on this
  build dismisses, and the scroll drag starts inside it.

### Rig guards, and putting a cell's toys away

`airplane on` and `dont_keep_activities on` change the **device**, not the app,
and the device undoes neither: not at the end of the cell, not on a failure,
not when the process exits. Left on, they fail every cell that follows —
including the interleaved control, so the run aborts as a rig fault after two
of them.

**`rotate` is the third of these and does not fit the same shape.** Orientation
outlives the cell on both platforms — `user_rotation` is a global setting on
Android and the simulator keeps its pose — but it is not an on/off pair, so the
runner's teardown replay has nothing to put back. This is measured, not
hypothetical: a D3 probe rotated once, and the interleaved control after it
failed with `no element named 'payButton' within 60s` — a rig fault wearing an
SDK finding's clothes. So `cell_rules` requires an **even number of turns**, and
both drivers' `launch()` refuses a device that is still turned, which is what
catches the cell that died between two of them. On Android both rotation
settings are read, because `user_rotation` only takes effect while
`accelerometer_rotation` is 0 and refusing on a stale value the sensor overrides
would break a rig nothing had turned.

Three things guard against the two on/off settings.

`cell_rules` refuses a cell that turns either on without turning it off, and
allows only that teardown to follow the action that reads the outcome.

**The runner replays a teardown the cell did not live to reach.** Declaring the
`off` is not the same as running it: `wait_label` raises on a timeout, so a cell
whose wait runs out unwinds its action loop with the `airplane off` still ahead
of it. When the loop exits through an exception, `run_cell` looks at how far the
cell got, and for every pair in `cells.TEARDOWN` whose `on` ran and whose `off`
is in the un-run tail, it performs the `off` itself — after the failure dump and
frame, so the evidence is of the failure rather than of the cleanup. It is best
effort and it says what it did: the cell gains a `teardown:` problem naming what
was replayed, or a second one if the replay itself failed, and `result.json`
carries `teardown_replayed`. The original failure is never displaced by it, and
a cell that put the device back is still a cell that failed.

And `AndroidDriver.launch` still refuses to start on a device left dirty by
either setting, quoting the command to clear it:

```bash
$ADB shell cmd connectivity airplane-mode disable
$ADB shell settings put global always_finish_activities 0
```

`always_finish_activities` is the worse of the two to inherit. Airplane mode
fails the next cell in a way that at least looks like a network problem; this
one makes the plugin's detach path fire on **every** cell that follows, so each
reports `error:resultUnknown` and each reads as an SDK finding rather than as
the one rig fault it is.

That last one is the backstop rather than the plan: a replay can fail too, and
`launch` is what catches a device left dirty by anything the replay could not
fix. It does **not** clear airplane mode itself — a run that silently repaired
the rig would be a run that had stopped telling you the rig was broken.

`airplane` reads the setting back after toggling it, and raises if it disagrees.
That is not defensive: the older `settings put global airplane_mode_on` plus a
broadcast needs a system permission on modern Android, and without it the
setting flips while the radios stay up — so a cell would report that the SDK
survived a network cut having measured nothing at all.

On iOS `airplane` raises instead. The simulator shares the host's network and
every route to cutting it — Network Link Conditioner, `pfctl` — needs sudo or
the GUI, so every network-cut cell is `platforms: [android]`.

## The example app's automation contract

Frozen in Phase 0. Under `--dart-define=PAYCROSS_E2E=true` the example renders
its outcome as one **bare `Text`** whose string is the label:

```
result:success:<txn>
result:failure:<recovery>:<txn>
result:cancelled
error:<PayCrossErrorCode.name>
```

`<txn>` may be empty — a failure before a transaction existed carries none.
Because of that, `result:success:` is a strict prefix of every success label, so
**labels are compared whole**; a `contains` match reports the no-transaction
case for a run that in fact carried one.

`<recovery>` is spelled as the server's own token — `retry`, `change_method`,
`restart`, `do_not_retry`, `contact_support`, or `unrecognized(<raw>)` for the
iOS-only unknown case — so a label compares directly against the merchant API's
`failure.recovery`. The package parses that token one way only, so the reverse
mapping lives in `example/lib/e2e_label.dart`.

Do **not** wrap that widget in `Semantics` and do not make it a `SelectableText`.
Both were verified on a live simulator to remove the node from the iOS
accessibility tree entirely, which is where the runner reads it.

One other define is read: `PAYCROSS_E2E_GOOGLE_PAY_MERCHANT_ID`, passed to
`PayCross.configure` when non-empty.

### Observing a non-result

A retryable decline produces no Dart result at all: the native sheet re-arms the
form and waits. `tree.sheet_rearmed` is how the runner sees that.

* **Android** — a node whose `text` is exactly `Payment failed. Please try
  again.` **or** exactly `Network error. Please try again.`, *and* one whose
  `text` is exactly `Pay <formatted amount>`. `PaymentViewModel` renders the
  first when the backend declined and the second when the request never got
  there, and a network-cut cell would otherwise look at a plainly re-armed
  sheet and report that it never re-armed. Exact match, because the amount
  header renders a bare `€10.00` node, the example's own button is
  `content-desc="Pay"`, and the wallet row is `content-desc="Pay with GPay"`.
* **iOS** — the identifiers `errorBanner` and `payButton`, with the payButton's
  label required to carry the cell's amount. Identifiers rather than copy,
  because the banner's wording is slated to change. Visibility is not required:
  the banner sits below the pinned footer after a decline and is in the tree
  while off-screen.

The banner is not unique to a retryable decline — it appears after any
non-cancel submit failure — so a `rearmed` verdict needs the predicate **and**
the merchant check (transaction `failed`, session still `open`).

## The rig

### Android

* `adb.exe` is a **Windows** binary driven from WSL. It cannot read a WSL path,
  so an APK is staged under `/mnt/c` and handed over in its Windows spelling.
  `adb shell` output arrives with CRLF; `adb exec-out` (screenshots) does not.
* A Flutter widget surfaces as `content-desc` with an empty `text`; the SDK's own
  Compose text does the opposite. Matching the wrong one cost an earlier run a
  false 270-second timeout.
* `launch()` asserts `ro.product.locale == en-US` and refuses to run otherwise,
  because the Pay button's text is `NumberFormat` output under the device locale
  and the predicate above matches it exactly. A re-imaged emulator fails loudly
  rather than silently missing every Pay button.
* The logcat cutoff is asked of the **device**, not computed in WSL: `logcat -t`
  reads device-local time and the emulator runs `Europe/Kiev`. A UTC cutoff pulls
  the whole ring buffer (110,082 lines against 2,187), and then one unrelated
  crash in it fails the cell, fails the interleaved control, and aborts the run.
  Capture is deliberately device-wide — an ANR is logged by `system_server`, not
  by the app — and the crash markers are then scoped to the example's package.
* **Never run two Android runs at once on one emulator.** `dump_tree` owns
  `/sdcard/ui.xml` (rm, dump, cat).
* Screenshots of the SDK sheet are black: `PaymentActivity` sets `FLAG_SECURE`,
  deliberately. The `.uix` dump is the real evidence on Android.

### iOS

* Everything runs over `ssh mac`. Every remote command re-exports `DEVELOPER_DIR`
  and `PATH`, because an ssh session inherits launchd's minimal environment.
* WebDriverAgent serves `http://127.0.0.1:8100` **on the Mac**. A failed WDA call
  is an HTTP 4xx with a JSON body rather than a transport error, so the wrapper
  checks `value.error` and raises — truncating the message, because the
  envelope's traceback runs to ~10 KB.
* **The WDA session is created without a `bundleId`, deliberately.** WDA reads
  one as "launch this", and for `XCUIApplication` launching means
  terminate-*then*-launch — which kills the app `launch()` started a moment
  earlier and takes its `--console-pty` capture with it, so criterion 3 then has
  an empty log to pass on. `forceAppLaunch: false` is a literal in the 16.2.2
  binary and does **not** stop it: measured on the rig 2026-08-29, where it
  failed every cell in `_check_console` (commit `ae3e460`). A session naming no
  bundle launches nothing and attaches to whatever is foreground, which is
  enough — everything asked of a session here is coordinate- or device-level and
  `/source` is unscoped. The full reasoning is in the capabilities comment in
  `drivers/ios.py`.
* `launch()` also deletes whatever session `/status` reports open, without
  checking whose it is: WDA has exactly one, and a foreign session would break
  this run just as thoroughly — a session bound to a bundle terminates its app
  when a new one displaces it. That makes **one run per WebDriverAgent** the
  standing rule, the way one run per emulator is on Android.
* The SDK emits no `os_log`, so the crash markers criterion 3 looks for reach the
  app's stdout and stderr and nowhere else. They are captured by launching
  through `simctl launch --console-pty` into a log file on the Mac. **That log is
  truncated by every `launch()`**, so a cell's logs are collected before the next
  launch (the runner does this; anything reading the console directly must too).
* The token reaches the simulator through `simctl pbcopy` fed from a `0600` file,
  so it is never a command-line argument.
* `cancel_challenge` taps `threeDSCancel`, which exists from PayCross 0.1.1
  onward. `cancel_form` matches the sheet's toolbar Cancel by identifier only,
  because the challenge bar's item is *labelled* "Cancel" too.
* **This WDA is strict about which endpoints take a session and which do not**,
  and the two lifecycle calls sit on opposite sides of that line. Measured
  against the running 16.2.2 on 2026-08-31, each answers `unknown command —
  Unhandled endpoint` to the other's form:

  | Endpoint | Form |
  |---|---|
  | `POST /wda/homescreen` | unsessioned |
  | `GET /wda/activeAppInfo` | unsessioned |
  | `POST /session/<id>/wda/apps/activate` | sessioned |

* `background` **re-activates and never re-launches**, for the same reason the
  session names no bundle: a launch is terminate-then-launch and would take the
  console capture with it.
* `_foreground_bundle` asks `activeAppInfo`, **not** `/source`'s root element.
  The root `XCUIElementTypeApplication` carries the app's *display* name in
  `name` — `PayCross Demo` on this build, `Paycross Flutter` in the pre-rename
  fixture — so comparing that against the bundle id never matches. The live
  root does carry a `bundleId` attribute of its own, but `tree.parse_wda` does
  not read it into `Node` and the committed fixture has none;
  `activeAppInfo` needs no new shape, no session and no full `/source` body.
* **The unified-log window is capped at an hour** (`LOG_WINDOW_CAP_SECONDS`).
  It is anchored to `launch()`, so it normally tracks the cell's own duration —
  10 s to 1313 s across the D2 run — but nothing bounded the host clock jumping,
  and one D2 cell that straddled a WSL sleep asked simctl for `--last 35354s`.
  The harm is asking for a 9.8-hour window at all: it is slow and fragile,
  *not* voluminous (a sleeping simulator logs almost nothing, and that cell's
  `logs.txt` was 2.0 MB against an ordinary cell's 4.8 MB). An hour clears the
  widest per-cell budget in the matrix (~3026 s) with room to spare, and the
  evidence header says when a window was capped. **The console half is never
  capped** — it is a byte offset from this launch, and `relaunch()` keeps that
  mark on purpose so a cell that relaunches halfway keeps its own criterion-3
  evidence.

### Moving the rig

Every path and host above is this workstation's, and every one is a default
rather than a constant: `PAYCROSS_E2E_ADB`, `PAYCROSS_E2E_STAGING_DIR` and
`PAYCROSS_E2E_WINDOWS_STAGING` on Android, `PAYCROSS_E2E_SSH_HOST` and
`PAYCROSS_E2E_MAC_ENV` on iOS. Set any of them to run on a second machine
without editing a driver. An empty value counts as unset.

### Deliberate asymmetries between the drivers

These look like drift and are not. Each one is a difference in the platform, not
in the code's ambitions.

| | Android | iOS |
|---|---|---|
| PAN read-back | `type_card(card, *, verify_pan=True)` reads the field back after typing | none — `type_card(card)` |
| Keyboard | dropped with a back key inside `type_card` | `dismiss_keyboard` is iOS-only, and on this simulator **nothing dismisses the CVV pad** |
| Amount matching | exact node-text match; `launch()` asserts `en-US` exactly | the `.`/`,` separator may be swapped, end-anchored, so `launch()` only refuses a non-English locale — and an unreadable one passes, because a simulator that has never had the key written answers with a complaint rather than a locale |
| WDA session | none | owns one; created with no `bundleId`, deletes whatever is open |
| Console capture | none (logcat is pulled per window) | owns one, truncated per launch |
| Screenshots | captured, but black (`FLAG_SECURE`) | **none at all** — the guard refuses every frame |
| Foreground check | `dumpsys window`, one adb call | `GET /wda/activeAppInfo`, unsessioned — **not** `/source`'s root, whose `name` is the app's display name |
| `dont_keep_activities` | the developer option, written and read back | raises: there is no activity to not keep |
| Settle after HOME / rotate | 3 s | 2 s — a simulator settles faster than an emulator |
| Device log window | `logcat -t <cutoff>`, computed **on the device** | `log show --last <n>s`, anchored to `launch()` and capped at an hour |

The PAN read-back is the regression path for the 0.3.1 caret bug, which 0.3.2
fixed and which the read-back proves 0.3.3 still holds against. It reports what
the field actually reads rather than blaming a cause, because a caret bug and a
mistyped tap look identical from there. Typing is paced at 0.4 s per digit so a
formatter that merely cannot keep up does not present as the caret bug
returning — a false finding against the SDK is the expensive direction to be
wrong in.

The iOS keypad is `payment-ios-sdk#16`: it is numeric, has no Done or Return
key, and `dismissKeyboard`, taps on `amount`, on TOTAL and on the navigation
bar, and a drag down the form all leave it up. It is **not fatal on the card
form** — `payButton` sits above the pad — so `type_card` asks best-effort. It
*is* fatal inside `acs()`, where the pad covers the ACS page's decline outcomes
and also swallows the swipe that would scroll them into view.

The amount asymmetry follows from the locale guard. Android refuses to run
anywhere but `en-US`, so there is nothing for its predicate to absorb. The
iOS simulator's locale is `en_US@rg=lvzzzz` — US English, Latvia region — so the
SDK renders `Pay €10,00` where the runner computes `€10.00`; the iOS match
accepts the swap and then end-anchors, so `Pay €10,000.00` no longer satisfies
€10.00.

## Evidence

```
<evidence-root>/<YYYYMMDD-HHMMSS>-<platform>/
  report.json                       the whole run: exit code, summary, warnings,
                                    one entry per cell. Written even when every
                                    cell was skipped
  progress.jsonl                    one line per cell, appended and fsynced as it happens
  <cell>/NN-<action>.uix            accessibility dump after every action
  <cell>/NN-<action>.png            screenshot, sheet-foreground steps only --
                                    black on Android, and never written on iOS
                                    (see Redaction)
  <cell>/NN-<action>-failed.uix     the tree at the moment a step failed
  <cell>/merchant.json              the session resource, scrubbed
  <cell>/logs.txt                   device log for the cell's window
  <cell>/result.json                label, ids, timings, problems, budget, the
                                    frames the screenshot guard refused, any
                                    teardown the runner replayed for the cell,
                                    the criterion-3 lines a cell declared and
                                    was excused (tolerated_crash_markers /
                                    tolerated_crash_lines), and a discovery
                                    cell's transaction-id cross-check
                                    (label_transaction_notes)
```

`report.json` is what a reader downstream — the nightly, the campaign report —
reads instead of parsing stdout. A run that skipped every cell still writes one,
which is exactly the run a report assembler wants; the directory it leaves holds
nothing else, and cannot satisfy a later resume, because `passed_cells` globs
`*/progress.jsonl` and there is none. An evidence root therefore accumulates
reports: **read the newest.**

`report.json` also carries `warnings` — things the run noticed and carried on
through, such as a bearer refresh that fell back to the `expires_in` the
API-Gateway cache is known to restate (`cognito-m2m#1`). They print as `WARN`
lines and never change the exit code: a warning that turns a green matrix red is
a warning the next person learns to silence.

The run id carries the platform because the two platforms are driven from two
shells: on a bare timestamp, an Android and an iOS run started in the same
second would share a directory and overwrite each other cell for cell.

Evidence is never committed.

### Redaction

Session tokens are ~1011-character JWTs and are live credentials. Every artifact
goes through `evidence.redact()` before it touches disk — accessibility dumps
included, because the example's token field still holds the token on the result
screen, and that is exactly where full tokens leaked in an earlier run.

**The rules and the reason their order is load-bearing are documented once, in
`evidence.py`'s module docstring. Read it there rather than re-deriving it here.**
In short: shape first, then the literal (or a long prefix) of a named secret,
then a key-based scrub of the merchant resource — and the runner's list of
secrets grows during a cell, because a GET on an open session re-mints a token
the runner never saw.

Screenshots **cannot** be redacted — a PNG is bytes, and `redact()` passes binary
through untouched by design. So a frame is captured only during `type_card`,
`tap_pay`, `acs` and `expect`, and only when the dump taken a moment earlier
agrees that the sheet is still foreground. If the payment resolved during that
dump, the frame would be the example's own screen, token field and all, and a
`grep` over the evidence tree cannot see into a compressed PNG.

**In practice that means no `.png` files on iOS at all, and black ones on
Android.** WebDriverAgent's `/source` returns the whole application tree, and
the example's token field is in it on every screen — so the guard's
"does this dump show the example?" test is true for every step, and every frame
is refused. The canonical runs bear this out: 16 screenshots on Android against
30 dumps, and **0** on iOS against the same 30. On Android the frames that do
get written are black, because `PaymentActivity` sets `FLAG_SECURE`. So on both
platforms the `.uix` dump is the real visual evidence, and the screenshot path
is currently costing more than it returns.

### Scan before you share

Anything leaving the evidence root — an issue attachment, a pasted excerpt —
gets both of these first, and both must print nothing:

```bash
grep -rlE 'eyJ[A-Za-z0-9_-]{20,}'                  <evidence-root>
grep -rlE '\[REDACTED-SESSION-TOKEN\][A-Za-z0-9_-]{8,}'  <evidence-root>
```

The first finds a token. The second finds a *partially* redacted one, which is
the failure mode that actually happened: a marker with token material still
trailing it means a rule ran in the wrong order.

## Tests

```bash
pytest tool/e2e/tests -q
```

854 tests, no device needed: every driver call is faked, so this covers the
parsing, the redaction, the label matching and the merchant verification — the
places where a silent mistake would be read as an SDK finding. The shipped cell
files are validated here too. CI runs this on Linux on every PR, in its own job,
alongside the plugin's 18 Dart tests and the example's own suite — the label
contract among them, since the demo app landed.

## Troubleshooting

Things live runs actually hit.

**`driver: the app's console capture is not running` (iOS).** A WebDriverAgent
session left open by an earlier run terminates the app when a new session
displaces it, taking the console capture with it. `launch()` now closes any open
session first; if it recurs, check `ssh mac 'curl -s http://127.0.0.1:8100/status'`
for a leftover `sessionId`, and check for stale `simctl` captures on the Mac.

**`no element named 'Session token' within 15s` (iOS).** Flutter merges a
*focused, empty* field's hint into its accessibility label, so the token field is
named `Session token` unfocused and `Session token\neyJhbGciOi…` in the moment
between the tap and the paste. That `eyJ…` is the example's hint text, not a
leaked token. The field is matched by prefix for this reason.

**`the keyboard is still up after dismissKeyboard and a tap on 'amount'` (iOS).**
`payment-ios-sdk#16`. Fatal only inside `acs()`. Nothing on this simulator
dismisses the CVV pad; if the ACS page's outcomes are unreachable, that is why.

**`the sheet never re-armed within 30s` (iOS) while the dump shows the banner.**
Check the payButton's label for the decimal separator. The simulator's region
renders `Pay €10,00`. The predicate accepts the swap now; a *different* locale
would need the same treatment, and there is no iOS locale guard yet.

**`device locale is '…', expected 'en-US'` (Android).** A re-imaged emulator.
Fix the AVD rather than the predicate.

**`after typing <pan> the card number field reads …` (Android).** Check digit
pacing before calling it an SDK bug — a formatter that cannot keep up looks
exactly like the caret bug.

**HTTP 401 mid-run.** The M2M token endpoint sits behind an API Gateway cache
that replays a stale `expires_in`, so a token can arrive already most of the way
through its life (`cognito-m2m#1`, `api-docs#57`, `payx-tkg#13`). The runner
schedules its refresh from the JWT `exp` claim and retries once on a 401.

**Cells you wanted to rerun were skipped.** That is the resume. Pass `--all`, or
— if the build changed — use a fresh `--evidence-root`.

**Nothing to run / `no 'control' cell runs on <platform>`.** Exit 2, before any
credential is read. Add a control cell, or check the cell's `platforms:` list.

## What is not here

Google Pay, saved cards and version floors (the release builds, the decline and
integration-error matrix, and app lifecycle are above). Every action and
expectation those dimensions own is declared in the driver protocol and raises
`NotImplementedError`, so cell files can be written against a stable vocabulary
before the drivers implement them — and a cell that reaches one early fails as
the authoring mistake it is rather than as a broken device.

Two of those refusals are permanent rather than pending, and each says so:
`airplane` on iOS (the simulator shares the host's network) and
`dont_keep_activities` on iOS (there is no activity to not keep). A cell that
needs either is `platforms: [android]`.

Known gaps, tracked for the next phase:

* The token-refresh paths (the 401 retry and the `exp`-scheduled refetch) have
  not been exercised by a live run. No run has happened to cross one, but that
  is luck rather than arithmetic: the refresh is scheduled from the token's own
  `exp`, and the gateway cache hands out tokens already most of the way through
  their life. At the documented numbers — 3600 s lifetime, 3300 s cache TTL,
  240 s margin — `_refresh_after` bottoms out around **60 s**, and its floor is
  0. A six-minute matrix **can** cross a refresh; none yet has. What is no
  longer silent is the *fallback*: an `exp` that cannot be read, or one further
  back than a whole token lifetime (this machine's clock, not the issuer's),
  now produces a `WARN` line and a `warnings` entry in `report.json`.
* **Screenshots are effectively dead weight.** iOS writes none — WDA's
  `/source` always contains the example's token field, so the redaction guard
  refuses every frame — and Android's are black under `FLAG_SECURE`. Either
  drop the screenshot path or give it something it can actually capture.

## Publishing

`tool/` is excluded from the published package by the repository's `.pubignore`,
which pub reads **instead of** `.gitignore` — which is why that file repeats the
ignore list rather than adding one line to it.
