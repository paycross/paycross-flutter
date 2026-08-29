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
| `--evidence-root` | where proof is written. Required. Outside any git checkout, and **one root per build** — see below. |
| `--env-file` | shell-style file holding the five sandbox keys. Required. |
| `--all` | rerun cells that already passed under this evidence root |
| `--app` | APK (Android) or a `.app` **on the Mac** (iOS) to install first. Implies `--all`. Omit to use what is already installed. |
| `--only` | run just this cell; repeatable |

A rerun **skips what already passed** under the same evidence root, so an
interrupted matrix is resumed rather than restarted. A pass carries no build
fingerprint, so a resume cannot tell yesterday's build from today's: give every
build a fresh `--evidence-root`. `--app` implies `--all` for the same reason.

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

Because of that rule, **every cell directory must contain a `control` cell that
runs on the platform being tested**. A directory without one is refused before a
credential is read (exit 2).

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
  options: {}                   # optional; merged (one key deep) over the
                                #   default mint body
actions:
  - paste_token
  - type_card
  - tap_pay
  - acs:approve
  - wait_result 180
expected:
  label: "result:success:<txn>"
  rearmed: false                # optional, defaults to false
  merchant:
    session_status: completed
    txn_count: 1
    txn_status: succeeded
    threeds:
      outcome: authenticated
      flow: challenge
      liability_shifted: true

# Optional. Merged one key deep over `expected`; `merchant` is merged key by
# key, so an override restates only the field that actually differs.
expected.ios:
  merchant:
    failure_recovery: change_method
```

Everything a cell can say is validated at load time — verbs, their arguments,
the label, and every merchant key and value — so a typo fails in seconds rather
than being read as an SDK finding twenty minutes into a matrix run. Cell files
are also validated in CI.

### Merchant assertions

`session_status`, `txn_count`, `txn_status`, `no_succeeded_txn`,
`failure_recovery`, `threeds`.

A key that is **absent is not asserted**. A key present with an explicit
**null** value asserts the field is absent — the two are different, and the
distinction is what `failure_recovery: null` is for.

Two things worth knowing before you write an expectation:

* `no_succeeded_txn: false` is a **no-op today**, not an assertion that a
  succeeded transaction exists. Only the truthy case is checked. Cells that were
  using it as an assertion had it removed rather than left to look meaningful.
* `threeds.eci` and `threeds.version` are deliberately not assertable. A sandbox
  upgrade must not present as a finding.

### Actions

| Action | What it does |
|---|---|
| `paste_token` | enters the session token and taps the **example app's** Pay, then waits for the sheet |
| `type_card` | fills the SDK's card form through the real fields |
| `tap_pay` | taps the **sheet's** Pay button |
| `acs:<outcome>` | waits for the sandbox ACS page and taps one outcome button |
| `cancel_challenge` | abandons an in-flight challenge and confirms |
| `cancel_form` | abandons the sheet from the card form and confirms |
| `expect rearmed` | waits up to 30 s for the `sheet_rearmed` predicate |
| `wait_result <s>` | waits up to `<s>` for a contract label |
| `background <s>`, `rotate`, `airplane on\|off`, `kill_activity` | declared, not implemented (D2/D3); a cell using one fails as an authoring mistake |

An argument is written `verb:arg` or `verb arg`, and the two are not
interchangeable in one case: **an argument containing a colon must use the
`verb:arg` form.** The parser splits on the first colon if the line has one at
all, so `wait_result 1:20` parses its verb as `wait_result 1` and is rejected as
an unknown action.

`acs:<outcome>` must match the sandbox ACS button's text **verbatim** — the
outcome is chosen by which button is tapped, not by the PAN. A typo there buys a
120-second page wait before it fails.

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
  again.` *and* one whose `text` is exactly `Pay <formatted amount>`. Exact
  match, because the amount header renders a bare `€10.00` node, the example's
  own button is `content-desc="Pay"`, and the wallet row is
  `content-desc="Pay with GPay"`.
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

### Deliberate asymmetries between the drivers

These look like drift and are not. Each one is a difference in the platform, not
in the code's ambitions.

| | Android | iOS |
|---|---|---|
| PAN read-back | `type_card(card, *, verify_pan=True)` reads the field back after typing | none — `type_card(card)` |
| Keyboard | dropped with a back key inside `type_card` | `dismiss_keyboard` is iOS-only, and on this simulator **nothing dismisses the CVV pad** |
| Amount matching | exact node-text match; `launch()` asserts `en-US` | no locale assertion; the `.`/`,` separator may be swapped, end-anchored |
| WDA session | none | owns one; deletes whatever is open |
| Console capture | none (logcat is pulled per window) | owns one, truncated per launch |

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
  progress.jsonl                    one line per cell, appended and fsynced as it happens
  <cell>/NN-<action>.uix            accessibility dump after every action
  <cell>/NN-<action>.png            screenshot, sheet-foreground steps only
  <cell>/NN-<action>-failed.uix     the tree at the moment a step failed
  <cell>/merchant.json              the session resource, scrubbed
  <cell>/logs.txt                   device log for the cell's window
  <cell>/result.json                label, ids, timings, problems, budget
```

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

447 tests, no device needed: every driver call is faked, so this covers the
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
Google Pay, saved cards and version floors. The four lifecycle actions are
declared in the driver protocol and raise `NotImplementedError`, so cell files
can be written against a stable vocabulary before the drivers implement them.

Known gaps, tracked for the next phase:

* Progress records carry no build fingerprint — hence one evidence root per
  build, by discipline rather than by check.
* The run's exit code is printed, not written to disk; there is no run-level
  `report.json`.
* The token-refresh paths (the 401 retry and the `exp`-scheduled refetch) have
  not been exercised by a live run — a full matrix is ~6 minutes and the refresh
  lands ~23–39 minutes out.
* `no_succeeded_txn: false` is a no-op, and `no_succeeded_txn` checks only
  `succeeded` — `authorized` and `captured` also mean money moved.
* `session.options` is a shallow merge, which is not enough for a "same
  customer" cell.
* `threeds` inner keys are not validated at load, so a typo there reads as a
  finding mid-run.
* iOS has no locale guard in `launch()` to match Android's.

## Publishing

`tool/` is excluded from the published package by the repository's `.pubignore`,
which pub reads **instead of** `.gitignore` — which is why that file repeats the
ignore list rather than adding one line to it.
