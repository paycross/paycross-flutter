# The outcome table — what a merchant's Dart code actually sees

The full matrix, rerun on `main` (**315602d**) against the PayCross **TEST**
sandbox on 2026-09-01. This is the table the integration guide is written from:
one row per integration error, session state, decline and lifecycle event, with
the label the example app renders and the merchant-API state behind it.

Everything here is measured on this run unless a row says otherwise. Where a
statement comes from reading source rather than from a cell, it says so.

## The run

| | Android | iOS |
|---|---|---|
| build id | `android-main-315602d-matrix-1` | `ios-main-315602d-matrix-1` |
| device | emulator `Medium_Phone`, API 35, `sdk_gphone64_x86_64`, locale `en-US` | iPhone 17 simulator, iOS 26.5, UDID `C311AFDC-…` |
| native SDK | `com.pay-cross:paycross-android:0.3.3` | `PayCross` / `PayCrossCore` 0.1.1 |
| plugin | `paycross_flutter` 0.1.0 at 315602d | same |
| app | `example` debug, `--dart-define=PAYCROSS_E2E=true` | same |
| built with | Flutter **3.44.8** (WSL) | Flutter **3.47.0** (Mac) |
| driver | `adb.exe` + `uiautomator` | WebDriverAgent 16.2.2 |

**The two hosts do not build with the same Flutter.** Both satisfy the
pubspec floor (`sdk: ^3.12.2`, first met by Flutter 3.44.2) and both compile
the same Dart label code from the same commit, but a cross-platform comparison
in this table is a comparison across two toolchains as well as two SDKs. It
does not confound anything **here**, because no row below diverges on its
label — but a future divergence must rule this out before it is called a
platform difference.

| dimension | Android | iOS | evidence root (latest run) |
|---|---|---|---|
| D0 core | 6/6 | 6/6 | `matrix1-android-d0/20260901-120420-android`, `matrix1-ios-d0/20260901-122713-ios` |
| D2 declines & errors | 19/19 | 16/16 | `matrix1-android-d2/20260901-124640-android`, `matrix1-ios-d2/20260901-124330-ios` |
| D3 lifecycle | 5/5 | 4/4 | `matrix1-android-d3/20260901-144150-android`, `matrix1-ios-d3/20260901-141018-ios` |
| D4 Google Pay | 3/3 | n/a | `matrix1-android-d4/20260901-145701-android` |
| D5 saved cards | 5/5 | 5/5 | `matrix1-android-d5/20260901-150316-android`, `matrix1-ios-d5/20260901-142047-ios` |
| **total** | **38/38** | **31/31** | |

Every root reports `0 failed, 0 skipped, **0 control checks**, aborted: no` and
exits 0. Zero control checks is the strong statement: no cell failed, so no cell
ever had to prove the rig was still honest. `host_suspended_seconds` is `0.0` on
every cell of every run — nothing straddled a host sleep.

Both redaction scans are silent over the whole evidence root:

```
grep -rlE 'eyJ[A-Za-z0-9_-]{20,}'                        evidence   # nothing
grep -rlE '\[REDACTED-SESSION-TOKEN\][A-Za-z0-9_-]{8,}'  evidence   # nothing
```

## The deployed sandbox

There is no version route to ask — a bare `GET https://api.test-pay-cross.com/`
is a 404 carrying no version header. What *is* observable is the challenge page
the rig dumps, and it identifies the build precisely
(`matrix1-android-d3/…/background_during_challenge/04-expect.uix`):

| observation | means |
|---|---|
| `Sandbox` badge present | the redesigned page (`payment-sandbox` `687bf4e`) |
| `Sandbox 3DS Challenge` **absent** from the tree | the old `<strong>` is gone; the phrase survives only in `<title>`, which no accessibility tree exposes |
| headings `AUTHENTICATION OUTCOMES` / `ISSUER DECLINES` / `TECHNICAL / OTHER` | the three group labels `origin/main` declares, CSS-uppercased |
| **33** outcome buttons | exactly the 33 outcome constants in `origin/main`'s `internal/challenge/render.go` |

**TEST is deployed at, or behaviourally identical to, `payment-sandbox`
`origin/main` (1d45a9a).** The four-month gap between that redesign being
written (2026-04-13) and reaching TEST — the drift that broke every Android
challenge cell mid-campaign — is closed. R1 holds on the same source:
`scenarios.go`'s `magicPANs` still has no `0069` or `0127`, which is why
`card_expired` and `invalid_cvv` are reached as ACS buttons rather than PANs.

---

## Integration errors and session states

`<txn>` is a transaction id; an **empty** `<txn>` is written as `:` with nothing
after it, and the emptiness carries meaning — it is what separates a failure
that never created a transaction from one that did.

| condition | how it arises | Android label | iOS label | merchant state | notes for the guide |
|---|---|---|---|---|---|
| blank token | `presentPayment('')` | `error:invalidToken` | `error:invalidToken` | session `open`, 0 txns | a **thrown** `PayCrossIntegrationError`, not a result. Asserted, never discovered. |
| malformed token | a non-JWT string | `result:failure:restart:` | `result:failure:restart:` | session `open`, 0 txns | a **result**, not a throw. `<txn>` empty. On iOS no sheet is ever presented (R9); Android reaches the same label by its own path. |
| token past `exp` | present > 900 s after minting | `result:failure:restart:` | `result:failure:restart:` | session **`open`**, 0 txns | label-identical to the malformed token. The *session* is still open — only the JWT died. |
| session `expired`, presented | present after `expires_at` | *(no label — a payable sheet)* | *(no label — a payable sheet)* | session `expired`, 1 failed txn from set-up | **Neither SDK detects a server-expired session at present time.** The shopper is shown a normal, fully payable form with no error banner. |
| session `expired`, submitted into | pay into that sheet | `result:failure:restart:414990cd-…` | `result:failure:restart:72e2fb4e-…` | session `expired`, **0 txns** | Refused correctly — but **the label names a transaction the session does not have.** See "The sentinel that stays" below. |
| session already paid | re-present a spent token | `result:success:d357f37f-…` | `result:success:3c0d515b-…` | session `completed`, **1 txn, still 1** | **No second authorization.** Re-presenting a spent token resolves as success against the existing transaction; the shopper is not charged twice. |

## The `PayCrossErrorCode` vocabulary

Eight codes, not the five the plan card guessed. Only `invalidToken` is
reachable from a cell; the rest are asserted from source, and the table says
which is which.

| code | raised where | platforms | in the matrix |
|---|---|---|---|
| `invalidToken` | native, both (`ERROR_INVALID_TOKEN` / `errorInvalidToken`) | both | **measured** — `error_blank_token`, identical on both |
| `notConfigured` | native, both | both | not exercised |
| `busy` | **Dart** (`paycross.dart:111`, the `_inFlight` guard) — native constants exist on both as a second line, but Dart refuses first | both | not exercised |
| `testPrefillInProduction` | **Dart only** (`paycross.dart:70`) | both | not exercised — needs `PayCrossEnvironment.production`, and this campaign never touches PROD |
| `noActivity` | native | **Android only** | not exercised |
| `noPresenter` | native | **iOS only** | not exercised |
| `resultUnknown` | native, both | both | not exercised. The one code that does **not** mean a mistake in merchant code — reconcile server-side rather than re-charging. |
| `unknown` | Dart mapper fallback (`payCrossErrorCodeFrom`) | both | not exercised |

## Declines

Every decline agrees across platforms — same label, same `failure.code`, same
`recovery`, same `network_decline_code`.

| cell | route | label (both platforms) | terminal or re-arm | `failure.code` | `recovery` | `network_decline_code` |
|---|---|---|---|---|---|---|
| `decline_do_not_honor` | PAN `…0002` | `result:cancelled` | **re-arms** | `do_not_honor` | `change_method` | `05` |
| `decline_insufficient_funds` | PAN `…9995` | `result:cancelled` | **re-arms** | `insufficient_funds` | `change_method` | `51` |
| `decline_fraud_suspected` | PAN `…0119` | `result:failure:do_not_retry:<txn>` | **terminal** | `fraud_suspected` | `do_not_retry` | `59` |
| `acs_do_not_honor` | ACS button | `result:cancelled` | **re-arms** | `do_not_honor` | `change_method` | `05` |
| `acs_card_expired` | ACS button | `result:cancelled` | **re-arms** | `card_expired` | `change_method` | `54` |
| `acs_invalid_cvv` | ACS button | `result:cancelled` | **re-arms** | `invalid_cvv` | `change_method` | *(none)* |
| `acs_authentication_rejected` | ACS button | `result:failure:do_not_retry:<txn>` | **terminal** | `authentication_rejected` | `do_not_retry` | *(none)* |
| `challenge_authentication_failed_rearm` (D0) | ACS button | `result:cancelled` | **re-arms** | `authentication_failed` | `change_method` | *(none)* |
| `challenge_fraud_suspected` (D0) | ACS button | `result:failure:do_not_retry:<txn>` | **terminal** | `fraud_suspected` | `do_not_retry` | `59` |

The pattern a merchant needs: **`change_method` re-arms the sheet and ends as
`result:cancelled` when the shopper gives up; `do_not_retry` is terminal and
comes back as `result:failure:do_not_retry:<txn>` directly.** The label's
recovery token is the server's own `failure.recovery` string, which is what
makes the comparison in this table a direct one.

### The caveat on that comparison, and it is not symmetric

Read from source, not measured — the sandbox only ever emits recoveries both
SDKs know:

* **Android** `Recovery.fromString` (`Recovery.kt`) maps anything unrecognised
  to `DO_NOT_RETRY`, discarding the server's string. The plugin's own bridge
  says so in a comment (`PayCrossPlugin.kt:305-314`): *"an unrecognised value
  has already collapsed to DO_NOT_RETRY before the plugin sees it."*
* **iOS** `Recovery.init(apiValue:)` (`PayCrossCore/Recovery.swift`) keeps it as
  `.unrecognized("<raw>")`, terminal for `isRetryable` but with the raw string
  intact, and `apiValue` round-trips it back out.

So for an unknown recovery, a merchant sees `RecoveryDoNotRetry` on Android and
`RecoveryUnrecognized(value)` on iOS — **the same retry decision, a different
Dart type**, and on Android the server's original string is unrecoverable.
Filed as
[payment-android-sdk#31](https://github.com/paycross/payment-android-sdk/issues/31).
Both platforms agree in the other direction: an absent or empty recovery becomes
`retry`, not `do_not_retry`.

## Timeout and network

| condition | how it arises | Android | iOS | merchant state | notes for the guide |
|---|---|---|---|---|---|
| provider never answers | PAN `…0051` | `result:failure:retry:6be72178-…` | `result:failure:retry:1baa933d-…` | txn `failed`, **`failure: null`** | The schema gap: a transaction failed by this path renders no `failure` block at all. Filed as **io.paycross#871**. |
| network cut before submit | airplane on, then cancel | `result:cancelled` | *n/a (R6)* | session `open`, **0 txns** | nothing was submitted |
| network cut during challenge | airplane on mid-challenge | `result:failure:retry:1c6ea3aa-…` | *n/a (R6)* | session `open`, txn `threeds_challenge_requested`, `threeds_result: null` | **Defensible.** Nothing succeeded, no liability shifted. |
| **network cut during polling** | airplane on after approval | `result:failure:retry:5fa5525c-…` | *n/a (R6)* | session **`completed`**, txn **`succeeded`**, 3DS `authenticated`/`challenge`, **`liability_shifted: true`**, eci `05` | **The divergence a merchant must handle.** See below. |

R6 keeps every network-cut cell Android-only: the iOS simulator shares the
host's network and every route to cutting it needs sudo or the GUI.

### The one a merchant cannot ignore

`airplane_during_polling` reports **`failure/retry` over a payment that
succeeded and shifted liability**. This run is the **third independent
reproduction** (594.6 s, session `01a05d…`, txn `5fa5525c-…`), on `main`, on the
current sandbox. It is `payment-android-sdk#25`.

The cell **passes**, and the pass is the finding: `<any>` for the label plus
hard merchant assertions is precisely the shape that catches a wrong label over
a right outcome.

Its sibling `airplane_during_challenge` produces a label that *reads* the same
and is **not the same result** — open session, nothing succeeded. The two must
never be reported as one finding.

For the guide: **a `retry` recovery on Android after a network interruption is
not proof the payment failed.** Reconcile server-side before re-collecting.
iOS is suspected on the same shape (`PaymentFlowRunner.swift`) and
**unmeasurable** on a simulator — that is a gap, not an acquittal.

## Lifecycle — background, rotate, kill

| event | how it arises | Android | iOS | merchant state |
|---|---|---|---|---|
| backgrounded 60 s during the challenge | `background 60` with the ACS page up | `result:success:8babd96e-…` | `result:success:c34c0a35-…` | `completed`, 1 txn `succeeded`, liability shifted, eci 05 |
| backgrounded 60 s during polling | `background 60` after approval | `result:success:13f6552a-…` | `result:success:deafabb8-…` | `completed`, 1 txn `succeeded` |
| rotated twice after submit | `rotate`, `rotate` | `result:success:86f5b222-…` | *n/a* | `completed`, 1 txn `succeeded` |
| process killed during the challenge | `kill_activity`, `relaunch` | **no label at all** | **no label at all** | session `open`, 1 txn at `threeds_challenge_requested`, none succeeded |

Backgrounding is safe on both platforms at 60 s. **A killed process produces no
result at all** — the Dart isolate dies with it, so the `expect no_result`
assertion is the point of the cell, not a shortfall. A merchant must treat a
disappeared app as *outcome unknown* and reconcile; there is no callback to wait
for. R13's warning stands unmeasured: iOS's poll deadline is a `ContinuousClock`
that advances while suspended, so a long background is a documented risk rather
than a tested one.

Two Android contracts worth stating because they are counter-intuitive
(R11, from D3):

* The **example app** absorbs its own configuration changes —
  `android:configChanges` lists `orientation|screenSize|locale|…` — so the
  plugin's detach path never fires on a rotation.
* The **SDK's `PaymentActivity` declares no `configChanges` at all**, so it *is*
  destroyed and recreated. The rotation cell measures the SDK's recreation.
* `cvv` is a plain `remember` (PCI DSS 3.3.1), so a rotation on the form clears
  it. The cell rotates *after* submit for that reason.
* `dont_keep_activities` is **inert** on this emulator, so the plugin's detach
  path is still unmeasured.

## Saved cards

Identical on both platforms, cell for cell and field for field.

| cell | Android | iOS | `stored_credentials` |
|---|---|---|---|
| `saved_card_1_save` | `result:success:<txn>` | `result:success:<txn>` | `saved_token` set, `save_operation: already_existing` |
| `saved_card_2_pay` | `result:success:<txn>` | `result:success:<txn>` | `used_token` set |
| `saved_card_3_challenge_save` | `result:success:<txn>` | `result:success:<txn>` | `saved_token` set, `already_existing`; 3DS `authenticated`/`challenge`, liability shifted, eci 05 |
| `saved_card_4_challenge_pay` | `result:success:<txn>` | `result:success:<txn>` | `used_token` set; 3DS `authenticated`/`challenge`, liability shifted, eci 05 |

`save_operation: already_existing` on both save cells is R4 behaving as
designed: re-saving the same PAN under the same `customer.merchant_reference`
returns the existing card, so the customer accumulates exactly one however many
times the pair runs.

## Google Pay (Android only)

| cell | session shape | button | label | merchant state |
|---|---|---|---|---|
| `google_pay_offered` | plain | **present** | `result:cancelled` | `open`, 0 txns |
| `google_pay_absent_on_aft` | `account_funding` in the create request | **absent** | `result:cancelled` | `open`, 0 txns |

R2's fallback was never needed: `account_funding` on the session **is** a live
per-session route to suppressing the wallet button on this TEST merchant, so
the absence cell is a real assertion rather than a gap in the table. The two
payment-through-Google-Pay cells stay parked on owner prerequisites (a signed-in
Google account — `dumpsys account` still reports `Accounts: 0` — and a Business
Console merchant id).

---

## The sentinel that stays `<any>`, and why that is a finding

`session_expired_server_submit` is the only discovery cell left in the matrix.
It reproduced on both platforms this run, which by the rerun rule would make it
a literal — and it **still cannot be pinned**:

```
ios   label  result:failure:restart:72e2fb4e-2066-42b3-9a1e-a324a87e272e
      result.json  label_transaction: '72e2fb4e-…' is not among the session's []
android label  result:failure:restart:414990cd-bbf0-4e65-9e5e-65c709c0ffb4
```

The session has **zero** transactions. Pinning `result:failure:restart:<txn>`
would make `verify_label_transaction` assert that the captured id names a
transaction on the session, and it does not. So the sentinel stays, and the
**label naming a transaction that does not exist is the thing to fix** — in the
SDKs, not in the cell.

The tooling half of this that D2 asked Phase 3 to build is **already on `main`**:
`label_transaction_notes` records the mismatch on discovery cells, added in
#37. Nothing further is needed there.

**This run does not close D2's open question about it, and could not.** D2 read
the chain in source — `POST /api/submit-card` apparently accepting a card on an
expired session and handing back a transaction id that is never recorded
against the session — and deliberately filed nothing, because the submit and
status HTTP bodies were never captured. The runner does not capture them, so
this rerun adds a second and third observation of the *symptom* and no new
evidence about the *cause*. The verification step D2 named still stands and
still belongs to whoever next has the rig: **capture the `/api/submit-card`
response and the first `/status/{id}` response for this cell.**

`d3/kill_process_during_challenge`'s `<none>` is not a discovery sentinel — it
is a deliberate assertion that no result may appear — and it holds on both
platforms.

## Divergences between the platforms

After 69 cells: **there is no measured label divergence anywhere in the
matrix.** Every cell that runs on both platforms produced the same label, the
same session status, the same transaction count and the same failure block.
That was checked mechanically rather than by eye — all 31 shared
cell/dimension pairs compared on label shape (transaction ids normalised to
`<txn>`) plus `session_status`, `txn_count`, `failure_code`, `recovery`,
`network_decline_code` and the four `threeds_result` fields: **0
divergences**.
That is the headline for the integration guide — a merchant integrating against
one platform's behaviour will not be surprised by the other.

What differs is coverage and source, not measured behaviour:

| difference | kind | detail |
|---|---|---|
| network-cut cells | **coverage** | Android-only (R6). The `airplane_during_polling` finding is therefore unproven, not disproven, on iOS. |
| `rotate_after_submit` | **coverage** | Android-only. |
| Google Pay | **coverage** | Android-only; Apple Pay does not exist in the iOS SDK. |
| unknown `recovery` | **source** | Android collapses to `do_not_retry`; iOS keeps `unrecognized(<raw>)`. Not reachable from the sandbox, so not measured. |
| Flutter toolchain | **rig** | 3.44.8 built the APK, 3.47.0 built the `.app`. |
| `txn_status` on `timeout_provider_never_answers` | **race, not platform** | both platforms have produced both `failed` and `processing` across runs — it is which side of core's 5-minute sweep the merchant read lands on. The cell asserts no `txn_status` for that reason. |

## Cells whose earlier evidence sat in a suspect window, now re-proven

Three windows of rig defects existed during Phases 1–2. Each is closed on
`main`, and this run re-measures what each one touched.

### Window A — the sandbox ACS page redesign (**Android only**)

`AndroidDriver.wait_acs` matched the page by its heading text. When the TEST
deployment caught up to `payment-sandbox` `687bf4e` overnight on 2026-08-30/31,
the string it looked for stopped being rendered and every Android cell that
waits for a challenge failed. Fixed by `ACS_MARKERS` (#37). **iOS was never
affected** — its driver matches `threeDSCancel` and the outcome buttons by
identifier, never page text.

Earlier Android evidence for these nine cells was valid when taken and is not
reproducible now. All nine are green on the current deployment:

| cell | dimension | now |
|---|---|---|
| `challenge_approve` | D0 | `result:success:c1db1e6d-…` |
| `challenge_authentication_failed_rearm` | D0 | `result:cancelled` |
| `challenge_fraud_suspected` | D0 | `result:failure:do_not_retry:7636e753-…` |
| `acs_authentication_rejected` | D2 | `result:failure:do_not_retry:b9ae6d18-…` |
| `acs_card_expired` | D2 | `result:cancelled` |
| `acs_do_not_honor` | D2 | `result:cancelled` |
| `acs_invalid_cvv` | D2 | `result:cancelled` |
| `airplane_during_challenge` | D2 | `result:failure:retry:1c6ea3aa-…` |
| `airplane_during_polling` | D2 | `result:failure:retry:5fa5525c-…` |

### Window B — WSL host suspends

Two of them: 2026-08-29T19:50Z–08-30T04:25Z, which turned Android
`airplane_during_challenge` and iOS `decline_do_not_honor` into artifacts
(both rerun at the time), and 2026-08-30T23:00Z–08-31T05:25Z, which ruined two
whole runs that were **discarded** (`20260830-224913-android`,
`20260830-225144-ios`). The guard that makes this visible —
`host_suspended_seconds`, #37 — now runs on every cell, and **every cell of
this matrix records `0.0`**. That is the positive statement the earlier
evidence could not make.

### Window C — driver-crash misattribution

D5's `saved_card_3_challenge_save` was scored **FAIL** on 2026-09-01 for a
`FATAL EXCEPTION: UiAutomation` that was the driver's own `uiautomator dump`,
not the app. `_attribute_fatal` (#38) fixed the attribution. The cell is
**green on both platforms** in this run.

Stated precisely, because it matters: **the fix was not exercised.** No
`FATAL EXCEPTION` appears in the cell's `logs.txt` this time and no
`DRIVER_CRASH_REASON` warning was raised — the crash simply did not recur. So
this run proves the cell is sound; #38's own unit fixtures, not this run, are
what prove the attribution logic.

## Findings and follow-ups

Nothing new was filed off this run. What it produced is one reproduction, one
open question it could not close, and one divergence that no cell can reach.

### 1. `payment-android-sdk#25` — reproduced, third independent session

`airplane_during_polling` reports `failure/retry` over a payment that succeeded
and shifted liability. Detail in "Timeout and network" above. Already filed; no
new issue.

### 2. The label names a transaction the session does not have — cause unmeasured

`session_expired_server_submit`. **Reproduced four times: on both platforms in
two independent runs** (android and iOS on 2026-08-30, android and iOS again in
this matrix), every one of them `session_status: expired` with
`transactions: []` and a non-empty `<txn>` in the label. The first pair was
found by reading `merchant.json` by hand; this pair is machine-recorded in
`label_transaction_notes`.

**The cause is still unmeasured, and this rerun could not measure it.** D2 read
the chain in source — `POST /api/submit-card` apparently accepting a card on an
expired session and returning a transaction id that is never recorded against
the session — and deliberately filed nothing, because the HTTP bodies were
never captured. The runner does not capture them, so a rerun can only add
observations of the symptom.

**Carried forward as a runner follow-up, not an issue.** The verification step
is small and exact: **capture the `/api/submit-card` response and the first
`/status/{id}` response for this cell.** If the submit really does answer
`success: true` on an expired session, that is a backend issue on
`paycross-core`, in the same family as
[io.paycross#871](https://github.com/paycross/io.paycross/issues/871) — two
read paths disagreeing about one transaction.

Until then the cell keeps its `<any>` sentinel, for the reason given above.

### 3. `Recovery` unknown values — a cross-platform type divergence, from source

Android collapses an unrecognised recovery to `do_not_retry` and discards the
server's string; iOS keeps `unrecognized(<raw>)`. Same retry decision, different
Dart type for a merchant. **No cell can reach it** — the sandbox emits only
recoveries both SDKs know — so this is read from source, not measured. Filed low-priority as
[payment-android-sdk#31](https://github.com/paycross/payment-android-sdk/issues/31);
detail in "Declines" above.

### Not a finding: the token-entry truncation

Android D2's first attempt lost 4–7 characters of the 1011-character token on
three consecutive cells **including the interleaved control**, inside the
driver, before the SDK was asked anything. A cold emulator restart cleared it
(the instance had been up 15 h 55 m). A rig fault, caught by
`_enter_token_text`'s read-back guard doing exactly its job. Not filed.

## What this run does not prove

* **iOS release builds.** Flutter refuses any non-debug build for the simulator,
  so every iOS cell here ran against a debug binary. Closing that needs a
  physical device through TestFlight.
* **The `airplane_during_polling` defect on iOS.** Unmeasurable on a simulator.
* **Google Pay as a payment method.** Presence and absence only; the two payment
  cells stay owner-gated.
* **The plugin's detach path on Android.** `dont_keep_activities` is inert on
  this emulator.
* **Version floors.** D6 has not run; it needs the owner's API-24 AVD and an
  older iOS runtime.
* **Anything on PROD.** By design, on every dimension, at every point.
