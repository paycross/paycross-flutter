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

### Budgets

Each cell gets a wall-clock budget derived from its actions. It is a **hang
backstop, not a performance assertion**: it is checked between steps, never
interrupts a driver call in progress, and a cell that finishes inside it has
proved nothing about how quickly it did so. The same goes for the `wait_result`
seconds in a cell file — they bound a hang, they do not describe expected
latency.

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
# override restates only the field that actually differs. D2 is expected to be
# the first live user of this path.
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
| `<none>` | no label may appear. For the Android process-kill cell, where the pending Dart call dies with the isolate and no result is delivered **by design**, so "the app said nothing" is the pass. Requires an `expect no_result` action. |

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
* `saved_card_saved` / `saved_card_used` assert **presence**, never a value:
  `evidence.scrub_resource` drops `stored_credentials.saved_token` and
  `used_token` by name before the verifier sees them, so what is left is the
  redaction marker for a card that was stored and `null` for one that was not.
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
| `type_cvv`, `tap_google_pay`, `select_saved_card`, `save_card` | wallet and saved-card entry (D4, D5) |
| `background <s>`, `rotate`, `kill_activity`, `dont_keep_activities on\|off` | lifecycle (D3) |

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

`paste_token` and `present_token` differ in one thing, and it matters. Both
enter the minted token and tap the example's Pay; **`paste_token` then waits for
the sheet and `present_token` does not.** Use `present_token` where no sheet is
the expected answer: on iOS a malformed or expired token is refused before
`present` is ever called, so waiting for a sheet costs a 60-second timeout and
then reports the wrong failure.

The last two rows are **in the grammar but not yet executable**, and so are
`expect google_pay`, `expect no_google_pay` and `expect saved_card`. The
vocabulary is opened a dimension at a time so cell files can be written against
a stable list; the dimension that owns a verb writes the driver method, and
every verb already reaches a `_perform` branch that calls it. Until the method
lands, the declaration on `Driver` raises `NotImplementedError` and a cell using
it fails as an **authoring mistake** rather than a device fault — so no control
check is spent proving a rig that was never in doubt. That distinction is the
whole reason the declarations exist: a missing attribute would raise
`AttributeError`, which the runner reads as a broken device, and two of those in
a row abort the run.

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

`acs:<outcome>` must match the sandbox ACS button's text **verbatim** — the
outcome is chosen by which button is tapped, not by the PAN. A typo there buys a
120-second page wait before it fails. Use `expect acs` where the cell has to see
the page and then leave it alone.

`wait` exists for exactly one recipe and it is not slowness. A session token's
JWT `exp` is mint + 900 s while the session's own `expires_at` is mint + 1200 s
(`session_ttl` + `session_grace_period`), so the only way to present a token
that is expired while its session is still open is to wait out the difference.
`cell_rules` refuses it in any cell whose id does not name an expiry.

### Rig guards, and putting a cell's toys away

`airplane on` and `dont_keep_activities on` change the **device**, not the app,
and nothing undoes them: not the end of the cell, not a failure, not an
exception. Left on, they fail every cell that follows — including the
interleaved control, so the run aborts as a rig fault after two of them.

Two things guard against that. `cell_rules` refuses a cell that turns either on
without turning it off, and allows only that teardown to follow the action that
reads the outcome. And `AndroidDriver.launch` refuses to start on a device that
is already in airplane mode, quoting the command to clear it:

```bash
$ADB shell cmd connectivity airplane-mode disable
```

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
  <cell>/result.json                label, ids, timings, problems, budget, and
                                    the frames the screenshot guard refused
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

564 tests, no device needed: every driver call is faked, so this covers the
parsing, the redaction, the label matching and the merchant verification — the
places where a silent mistake would be read as an SDK finding. The shipped cell
files are validated here too. CI runs this on Linux on every PR, in its own job,
alongside the plugin's 18 Dart tests and the example's 10 for the label contract.

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

Phases 1–4: release builds, the decline and integration-error matrix, lifecycle,
Google Pay, saved cards and version floors. Every action and expectation those
dimensions own is declared in the driver protocol and raises
`NotImplementedError`, so cell files can be written against a stable vocabulary
before the drivers implement them — and a cell that reaches one early fails as
the authoring mistake it is rather than as a broken device.

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
