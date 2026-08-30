# D2 — the decline, integration-error and network-failure matrix

Run 2026-08-29/30 against the PayCross **TEST** sandbox, on the debug builds of
the example app (`--dart-define=PAYCROSS_E2E=true`).

| | Android | iOS |
|---|---|---|
| build id | `android-0.3.3-debug` | `ios-0.1.1-debug` |
| device | emulator `Medium_Phone`, API 35 | iPhone 17 simulator, iOS 26.5 |
| SDK | `payment-android-sdk` 0.3.3 | `PayCross` / `PayCrossCore` 0.1.1 |
| summary | `18 cells, 16 passed, 2 failed, 0 skipped, 2 control checks, aborted: no` | `15 cells, 13 passed, 2 failed, 0 skipped, 2 control checks, aborted: no` |
| exit | 1 | 1 |

Neither run aborted, and **every interleaved control passed**, so each failure
stands on its own rather than being one rig problem seen many times.

Three of the cells are Android-only: the iOS simulator shares the host's
network and has no airplane mode (R6).

The summary line above is the **first full pass**, over eighteen cells.
`session_expired_server_submit` was written during the run to answer a question
the pass raised, so the dimension is now **19 cells on Android and 16 on iOS**,
and that is what a future full pass will report.

## Results

### Android — `evidence/d2-debug-android/20260829-193257-android`

| cell | expected label | measured label | session | txns | txn status | verdict |
|---|---|---|---|---|---|---|
| `acs_authentication_rejected` | `result:failure:do_not_retry:<txn>` | `result:failure:do_not_retry:2465e5c3-…` | open | 1 | failed | as expected |
| `acs_card_expired` | rearm → `result:cancelled` | `result:cancelled` | open | 1 | failed | as expected |
| `acs_do_not_honor` | rearm → `result:cancelled` | `result:cancelled` | open | 1 | failed | as expected |
| `acs_invalid_cvv` | rearm → `result:cancelled` | `result:cancelled` | open | 1 | failed | as expected |
| `airplane_before_submit` | rearm → `result:cancelled` | `result:cancelled` | open | **0** | — | as expected |
| `airplane_during_challenge` | discover | `result:failure:retry:036268f0-…` | expired | 1 | failed | sleep artifact, rerun |
| `airplane_during_polling` | discover | **`result:failure:retry:fd3ea19c-…`** | **completed** | 1 | **succeeded** | **FINDING** |
| `cancel_on_form` | `result:cancelled` | `result:cancelled` | open | **0** | — | as expected |
| `completed_session_represented` | discover | `result:success:5a05e6b7-…` | completed | **1** | succeeded | measured |
| `control` | `result:success:<txn>` | `result:success:93a463f0-…` | completed | 1 | succeeded | as expected |
| `decline_do_not_honor` | rearm → `result:cancelled` | `result:cancelled` | open | 1 | failed | as expected |
| `decline_fraud_suspected` | `result:failure:do_not_retry:<txn>` | `result:failure:do_not_retry:1d78ea45-…` | open | 1 | failed | as expected |
| `decline_insufficient_funds` | rearm → `result:cancelled` | `result:cancelled` | open | 1 | failed | as expected |
| `error_blank_token` | `error:invalidToken` | `error:invalidToken` | open | 0 | — | as expected |
| `error_malformed_token` | discover | `result:failure:restart:` | open | 0 | — | measured |
| `session_expired_jwt` | discover | `result:failure:restart:` | open | 0 | — | measured |
| `session_expired_server` | discover | *(no label)* | expired | 1 | failed | **FINDING** |
| `timeout_provider_never_answers` | discover | `result:failure:retry:99bc1afe-…` | open | 1 | failed | measured |

### iOS — `evidence/d2-debug-ios/20260829-194116-ios`

| cell | expected label | measured label | session | txns | txn status | verdict |
|---|---|---|---|---|---|---|
| `acs_authentication_rejected` | `result:failure:do_not_retry:<txn>` | `result:failure:do_not_retry:ac7b1505-…` | open | 1 | failed | as expected |
| `acs_card_expired` | rearm → `result:cancelled` | `result:cancelled` | open | 1 | failed | as expected |
| `acs_do_not_honor` | rearm → `result:cancelled` | `result:cancelled` | open | 1 | failed | as expected |
| `acs_invalid_cvv` | rearm → `result:cancelled` | `result:cancelled` | open | 1 | failed | as expected |
| `cancel_on_form` | `result:cancelled` | `result:cancelled` | open | **0** | — | as expected |
| `completed_session_represented` | discover | `result:success:a257f5b1-…` | completed | **1** | succeeded | measured |
| `control` | `result:success:<txn>` | `result:success:f7633d7a-…` | completed | 1 | succeeded | as expected |
| `decline_do_not_honor` | rearm → `result:cancelled` | `result:cancelled` | expired | 0 | — | sleep artifact, rerun → PASS |
| `decline_fraud_suspected` | `result:failure:do_not_retry:<txn>` | `result:failure:do_not_retry:e7c040ba-…` | open | 1 | failed | as expected |
| `decline_insufficient_funds` | rearm → `result:cancelled` | `result:cancelled` | open | 1 | failed | as expected |
| `error_blank_token` | `error:invalidToken` | `error:invalidToken` | open | 0 | — | as expected |
| `error_malformed_token` | discover | `result:failure:restart:` | open | 0 | — | measured |
| `session_expired_jwt` | discover | `result:failure:restart:` | open | 0 | — | measured |
| `session_expired_server` | discover | *(no label)* | expired | 1 | failed | **FINDING** |
| `timeout_provider_never_answers` | discover | `result:failure:retry:5b5cc9f0-…` | open | 1 | processing | measured |

## The reruns

Three cells were rerun with `--only … --all` on the same evidence roots — two
because the host sleep had turned them into artifacts rather than
measurements, and one because it was the finding and a finding is worth
proving twice.

### Android — `evidence/d2-debug-android/20260830-100336-android`

| cell | measured label | session | txns | txn status | seconds | verdict |
|---|---|---|---|---|---|---|
| `airplane_during_challenge` | `result:failure:retry:85844815-…` | open | 1 | `threeds_challenge_requested` | 612 | PASS — the artifact replaced by a real measurement |
| `airplane_during_polling` | **`result:failure:retry:1f9aa0d3-…`** | **completed** | 1 | **succeeded** | 609 | PASS — **the finding, reproduced** |

`airplane_during_challenge` is the cell the sleep caught mid-flight, and the
rerun both replaces it and settles what it means. Its session came back
**open** with the transaction still at `threeds_challenge_requested` and
`threeds_result: null` — nothing succeeded and no liability shifted — so
`failure:retry` is a defensible answer there. **It is not the same result as
its sibling** even though the two labels read alike, and the two must not be
reported as one finding.

### iOS — `evidence/d2-debug-ios/20260830-100336-ios`

| cell | measured label | session | txns | txn status | seconds | verdict |
|---|---|---|---|---|---|---|
| `decline_do_not_honor` | `result:cancelled` | open | 1 | failed | 63 | PASS — sleep artifact confirmed |

63 seconds against the 9.5 hours the first attempt took, `rearmed: true`, and
a complete failure block on the transaction (`code: do_not_honor`,
`recovery: change_method`, `network_decline_code: "05"`). The first attempt
was the sleep and nothing else.

Both reruns also carried a first draft of `session_expired_server_submit` that
failed by design — see below.

## Paying into a server-expired session

`session_expired_server` measured that both SDKs present a fully payable form
on a session the server has already killed, and stops there. The obvious next
question — what happens when the shopper does the thing the form invites — was
not in the original cell set. `session_expired_server_submit` was written to
answer it, with the **approve** PAN, so that the one outcome that matters most
(money moving on a closed session) would be visible rather than hidden behind a
card that declines anyway.

The verdicts were fixed in writing **before** the run, so the answer could not
be fitted to it:

| measured | verdict |
|---|---|
| `result:failure:restart:` or a re-arm with a banner | correct, no finding |
| a hang, a crash, or `result:failure:retry:` | finding |
| `result:success:` | **serious** finding |

### The result: both SDKs refuse correctly

| | Android — `evidence/d2-debug-android/20260830-114945-android` | iOS — `evidence/d2-debug-ios/20260830-114950-ios` |
|---|---|---|
| label | `result:failure:restart:3a9c6d3b-…` | `result:failure:restart:71dfcbf5-…` |
| session | `01a05281-149e-7026-a049-8f94599b6803` — **expired** | `01a05281-2518-712c-92a3-b7a60e5101f3` — **expired** |
| transactions on the session | **0** | **0** |
| `no_succeeded_txn` | held | held |
| seconds | 1304 | 1286 |

**No money moved on either platform**, the session stayed expired holding
nothing, and both SDKs landed on the non-retryable `restart` — the same
recovery they give for an expired JWT and a malformed token. That is the
"correct, no finding" row of the table above, and it is the answer to the
question `session_expired_server` left open: the sheet is payable, but the
payment is refused.

### The measurement inside the pass: the label names a transaction that the session does not have

The cell left `txn_count` unasserted on purpose, because whether a submit on a
dead session creates a transaction was part of the question. The answer is
**stranger than either option**: the label's transaction field is *non-empty*
on both platforms, and the merchant API's session holds `"transactions": []`.

So the id in the label is not resolvable against the session it belongs to. A
merchant reconciling `Failure.transactionId` against `GET /payment-sessions/{id}`
finds nothing there.

Where the id comes from is **read in source, not observed on the wire**, and
the distinction matters:

- The initialize path cannot have produced it. `PaymentViewModel.kt:137` builds
  its `restart` from `transactionId ?: session?.latestTransactionId`, and on a
  session with no transactions both are null — that path yields an *empty*
  `<txn>`, which is exactly what `session_expired_jwt` measures.
- So the card really was submitted: `submitWithRetry` (`:304-306`) only starts
  polling when `submitCard` answers `success == true` with a non-null
  `transactionId`, and the only route from there to a non-retryable failure
  naming a transaction is `handleStatus`'s `STATUS_FAILED` branch (`:379-403`)
  with a `recovery` that is not retryable.

Read together: **`POST /api/submit-card` accepted a card on an expired session
and handed back a transaction id**, the status endpoint later reported that id
as failed with a `restart` recovery, and no transaction was ever recorded
against the session. The refusal happens downstream of the submit, not at it.

This was **not filed as an issue**, deliberately. The chain above is inference
from `origin/main` plus two measured endpoints; the submit and status HTTP
bodies were never captured, and an issue asserting backend behaviour on that
basis could easily be wrong in its particulars. The verification step is
small and exact, and belongs to whoever next has the rig: **capture the
`/api/submit-card` response and the first `/status/{id}` response for this
cell.** If the submit really does answer `success: true` on an expired
session, that is a backend issue on `paycross-core`, in the same family as
[io.paycross#871](https://github.com/paycross/io.paycross/issues/871) — two
read paths disagreeing about one transaction.

### Why this cell stays `<any>`, and the tooling gap it exposes

`session_expired_server_submit` is the one discovery cell that reproduced
across both platforms and still **cannot be pinned**. Pinning
`result:failure:restart:<txn>` would make it fail:
`verify.verify_label_transaction` requires a non-empty captured `<txn>` to name
a transaction on the session, and this one names none.

That is worth stating plainly, because it cuts the other way too. **`<any>`
silently disables that check.** `verify.match_label` captures nothing for
`<any>` (`verify.py:107-108`), so the `transaction_id` reaching
`verify_label_transaction` at `runner.py:915` is `None`, and the function
returns immediately. Every discovery cell in the matrix can therefore report a
transaction id that does not exist and pass without comment — which is exactly
what happened here, and it took reading `merchant.json` by hand to notice.

Worth a runner change in Phase 3: capture and cross-check the transaction id
for `<any>` cells too, recording the mismatch rather than asserting a label.
The information is already in `result.json`; nothing is checking it.

## The cell that had to be rewritten

The first draft of `session_expired_server_submit` copied its sibling's
opening — decline, `expect rearmed`, cancel, then `wait_expired` — while
keeping the **approve** PAN the submit step needs. A cell carries one card, so
the set-up payment used the approve card and simply **succeeded**: there was no
re-arm to observe, no Cancel button to press, and the session reached
`completed`, which can never go on to expire. The cell's own premise was
destroyed by its set-up.

It failed that way once on each platform, inside the reruns
(`20260830-100336-*`): iOS session `01a05220-d801-7352-9632-bf1c1174cfb4` with
txn `df9b2fde-…` succeeded, android session `01a05232-83c9-702f-8b6e-cdba6215a17c`.
Both aborted at the cancel rather than burning the 1400 s wait, and both
interleaved controls passed straight afterwards, so the rig was never in doubt.

The fix was to **drop the set-up entirely**. The sibling needs a failed
transaction only to make its `<txn>` non-empty; this cell needs nothing but a
server-expired session, so it now waits one out and submits into it. Recorded
here so it is not retried.

## The pins

Six of the seven `<any>` cells measured the same label twice and are now
literals in the cell files, so the matrix asserts where it used to record.
"Twice" means either two runs on one platform (the android-only airplane
cells) or the same label on both platforms — both are independent
observations of one behaviour.

| cell | pinned to | reproduced by |
|---|---|---|
| `completed_session_represented` | `result:success:<txn>` | android + iOS agree |
| `error_malformed_token` | `result:failure:restart:` | android + iOS agree |
| `session_expired_jwt` | `result:failure:restart:` | android + iOS agree |
| `timeout_provider_never_answers` | `result:failure:retry:<txn>` | android + iOS agree |
| `airplane_during_challenge` | `result:failure:retry:<txn>` | android, two runs |
| `airplane_during_polling` | `result:failure:retry:<txn>` | android, two runs |

Two are pinned **without** a `<txn>` placeholder. `error_malformed_token` and
`session_expired_jwt` both measured an empty transaction field, and that
emptiness carries meaning: it is what tells `session_expired_jwt` apart from
`session_expired_server`. A placeholder would quietly accept a transaction id
that should never exist.

### The pins, proven live

Every pin was first replayed **offline** against the recorded evidence through
the real `verify.match_label` and `verify.verify_label_transaction`: 12 of 12
combinations passed, transaction cross-check included. Then each was rerun
against a **fresh** session, which is what actually proves an assertion — a
literal that only matches the run it was copied from is not an assertion.

Android — `evidence/d2-debug-android/20260830-121620-android`, iOS —
`evidence/d2-debug-ios/20260830-121626-ios`.

| cell | android | iOS |
|---|---|---|
| `completed_session_represented` | PASS `result:success:953a6481-…` | PASS `result:success:ba1195a5-…` |
| `error_malformed_token` | PASS `result:failure:restart:` | PASS `result:failure:restart:` |
| `session_expired_jwt` | label matched; **merchant assertion failed** — see below | PASS `result:failure:restart:` |
| `timeout_provider_never_answers` | PASS `result:failure:retry:4d33451a-…` | PASS `result:failure:retry:42ffca0d-…` |
| `airplane_during_challenge` | PASS `result:failure:retry:d99d6e34-…` | *(android only, R6)* |
| `airplane_during_polling` | PASS `result:failure:retry:8a79f874-…` | *(android only, R6)* |

`6 cells, 5 passed, 1 failed, 1 control check` on android (exit 1),
`4 cells, 4 passed` on iOS (exit 0). **All ten pinned labels matched on fresh
sessions**, including the two id-free literals. The single failure is a
merchant-state assertion, not a label.

It also gave `airplane_during_polling` a **third** reproduction —
session `01a052a2-65bf-71f3-9907-40c816bf1ab9`, transaction `8a79f874-…`
succeeded with `liability_shifted: true`, SDK label `result:failure:retry:` —
added as a comment on
[payment-android-sdk#25](https://github.com/paycross/payment-android-sdk/issues/25).
Three for three at 592 / 609 / 595 s in the cell: not a flake.

### `session_expired_jwt` is too tightly timed for this rig

The android rerun failed on `session_status: expected 'open', got 'expired'`
while its **label matched exactly**. The cell's own comment predicted this and
said what to do — *"if it ever reports session_status `expired`, check the clock
before checking the SDK"* — so the clock was checked:

| | |
|---|---|
| session `created_at` | 12:39:08Z |
| session `expires_at` | 12:59:08Z (1200 s) |
| the sweeper flipped it at | 13:00:46Z |
| the cell took | **1420 s** against an action budget of `wait 960` + `wait_result 90` = 1050 s |

The cell needs the merchant read to land inside a window that opens at 900 s
(the JWT's own `exp`) and closes at 1200 s. On this rig launch, install, token
handling and evidence writing cost ~370 s on top of the action list, which does
not fit — so `wait 960` leaves no headroom at all and the cell wins or loses on
how busy the emulator is. It won twice and lost once: **flaky at roughly one in
three, and flaky in the cell rather than in the SDK.**

The interleaved control passed straight afterwards, so the rig was sound; this
is the cell's arithmetic, not the device.

**Recommended fix, not applied here** (it needs another ~25 minute run to
prove, and this task is out of device time): drop `session_status: open` from
the expectation. It is not the assertion that carries the cell — `txn_count: 0`
already tells `session_expired_jwt` apart from `session_expired_server`, which
holds one transaction, and the empty `<txn>` in the pinned label says the same
thing a second way. `session_status` only restates which clock ran out first,
which is precisely the thing the rig cannot deliver reliably.

`airplane_during_polling`'s pin **asserts a bug on purpose.** Its merchant
assertions already say the money moved and liability shifted; the label now
says the SDK called that a retryable failure. When
[payment-android-sdk#25](https://github.com/paycross/payment-android-sdk/issues/25)
is fixed the cell will go red, and that red is the fix arriving — the cell's
own comment says so. Leaving `<any>` would have let the fix land unremarked.

### `session_expired_server` is not pinned, and cannot pass as it is written

It produced no label at all, on either platform, so there is no literal to
pin — and the reason is structural rather than a defect in the SDK: the cell's
action list stops at `present_token`, so nothing downstream can resolve a
label, while `expected.label: "<any>"` requires one. **As authored it is a
guaranteed red on both platforms in every future D2 run.**

The runner's vocabulary already has the answer — `expect no_result` paired
with `label: "<none>"`, a pairing `cells.py` enforces in both directions — but
it is not a two-line change. The runner overwrites the recorded label on
*every* `wait_result`, and this cell has an earlier one that records
`result:cancelled` after the cancel; `<none>` only works if that is dropped
too, which costs the cell its proof that the cancel produced a label.

Left for Phase 3 on purpose, and for a second reason:
`session_expired_server_submit` may supersede it. If the SDK turns out to
refuse at submit, folding the two cells into one is likely better than
converting this one — and deciding that before the submit measurement was in
would have been a guess.

## The discovery cells, both platforms

Every `<any>` cell that ran on both platforms produced **the same label on
both**. There is no Android/iOS divergence anywhere in this dimension — which
is itself worth saying, because it means a merchant integrating against one
platform's behaviour will not be surprised by the other.

| cell | Android | iOS | agree | pinned |
|---|---|---|---|---|
| `completed_session_represented` | `result:success:<txn>` | `result:success:<txn>` | yes | yes |
| `error_malformed_token` | `result:failure:restart:` (empty `<txn>`) | `result:failure:restart:` (empty `<txn>`) | yes | yes |
| `session_expired_jwt` | `result:failure:restart:` (empty `<txn>`) | `result:failure:restart:` (empty `<txn>`) | yes | yes |
| `timeout_provider_never_answers` | `result:failure:retry:<txn>` | `result:failure:retry:<txn>` | yes | yes |
| `session_expired_server` | no label; payable sheet | no label; payable sheet | yes | **no — see above** |
| `session_expired_server_submit` | `result:failure:restart:<txn>` | `result:failure:restart:<txn>` | yes | **no — the `<txn>` names no transaction** |
| `airplane_during_challenge` | `result:failure:retry:<txn>` | *(android only, R6)* | — | yes |
| `airplane_during_polling` | `result:failure:retry:<txn>` | *(android only, R6)* | — | yes |

Two of these settle open questions from the plan:

- **R9 holds, and holds wider than it claimed.** It predicted that on iOS a
  malformed token and an expired JWT are label-identical (`result:failure:restart:`
  with an empty `<txn>`, no sheet). Both are confirmed on iOS — and Android,
  whose path R9 said was unread, produces exactly the same two labels.
- **Android's poll deadline, never read before, is 480 s** —
  `PaymentViewModel.POLL_DEADLINE_MS = 8 * 60 * 1000L`, with
  `POLL_INTERVAL_MS = 2000L`. That is the same deadline as iOS's
  `FlowLimits.pollDeadline`, so the `wait_result 600` in the two `airplane_during_*`
  cells was correctly sized — by luck, since it was sized off iOS.

## The two clocks

Measured by minting one throwaway TEST session and decoding its JWT claims
in-process (the token was never printed, written or logged):

| | |
|---|---|
| JWT `iat` → `exp` | **900 s** |
| session `created_at` → `expires_at` | **1200 s** |
| grace period | **300 s** |

The session outlives its own token by five minutes. This is why `wait_expired`
has to re-mint on every poll: without it the token dies 300 s before the session
does, and a cell aiming at the server's verdict measures JWT expiry instead.

## Findings

### 1. Network loss during polling reports `failure/retry` over a payment that succeeded (Android)

`airplane_during_polling`. The cell **passed** — `<any>` for the label plus hard
merchant assertions is exactly the shape that catches this, so a pass here is
the finding.

Filed as
**[payment-android-sdk#25](https://github.com/paycross/payment-android-sdk/issues/25)**,
after reproducing it on a second, independent session.

| | first run | rerun |
|---|---|---|
| session | `01a0512f-186f-713d-8d87-3bf2bb8345d6` — completed | `01a05229-3a71-7369-b538-29bf557f8db7` — completed |
| transaction | `fd3ea19c-…` — **succeeded** | `1f9aa0d3-…` — **succeeded** |
| `threeds_result` | authenticated, challenge, **`liability_shifted: true`**, eci 05 | identical |
| SDK label | **`result:failure:retry:fd3ea19c-…`** | **`result:failure:retry:1f9aa0d3-…`** |
| seconds | 592 | 609 |

`PaymentViewModel.pollStatus` swallows `IOException`/`HttpException` as
transient, runs out its 480 s deadline and emits
`PayCrossResult.Failure(transactionId, Recovery.RETRY)` — hardcoded. It is not
reporting an observed failure; it is reporting the absence of an answer as one.
`Recovery` has no member meaning "outcome unknown, verify before re-collecting",
and the SDK contradicts its own stated policy: `isRetryable`'s docstring says
unknown recoveries "fail closed", yet the one genuinely-unknown case fails open.

The proposed fix in #25 is a new `Recovery` member meaning *outcome unknown,
verify before re-collecting*, returned from the deadline branch. It is a new
enum member and therefore source-incompatible for an exhaustive `when` in
merchant code, so it belongs in a minor release. Shortening or lengthening the
deadline is explicitly **not** proposed: no deadline makes an unreachable
network reachable, and the report at the deadline is wrong at any duration.

iOS is **suspected but unmeasurable** — the same shape is in
`PaymentFlowRunner.swift`, but R6 puts network cuts out of reach on a
simulator. The issue says so rather than implying the defect is cross-platform;
if it is confirmed on iOS it needs its own issue on that SDK.

### 2. Both platforms present a fully payable sheet for a server-expired session

`session_expired_server`, on Android *and* iOS. Both recorded
`driver: no contract label within 90.0s`, which is **not a hang**: the cell's
action list stops at `present_token` and never types a card or taps Pay, so no
label can arrive.

What the final dump shows is the finding. On both platforms the last dump is
element-for-element identical to the `present_token` dump — card number, expiry,
CVV and a live Pay button (`Pay €10.00` / `Pay EUR 10,00`), with **no error
banner** — on a session the server has already expired.

| | Android | iOS |
|---|---|---|
| session | `01a05154-829e-73ad-b5eb-16ea593c9fcb` | `01a0513f-13ea-7166-8347-b478886bb5ed` |
| status | expired | expired |
| last dump | payable form | payable form |

So neither SDK detects a server-expired session at present time while the JWT is
still valid. A customer is shown a normal payment form on a dead session and can
only learn at submit — if then. This contradicts the reading in the cell's own
comment, which expected `SessionResolution.swift:37-40` to resolve `expired` to
`.failed(recovery: .restart)` right after presenting.

`session_expired_server_submit` was written to answer the question that leaves
open: what happens when the shopper actually pays into it.

### 3. A failed transaction can render `failure: null`

Filed as **paycross/io.paycross#871**. Measured here on
`timeout_provider_never_answers` (Android txn `99bc1afe-…`, `failed`,
`failure: null`) and `airplane_during_challenge` (txn `036268f0-…`, same).

The contrast within this run is the clearest evidence: `session_expired_server`'s
transaction `25ca7216-…`, failed by the ordinary decline path, renders a
complete block — `code: do_not_honor`, `recovery: change_method`,
`network_decline_code: "05"`. Same endpoint, same resource, same `status:
failed`; only the code path that set it differs.

## Issues filed

| # | repo | subject |
|---|---|---|
| [payment-testing-tool#17](https://github.com/paycross/payment-testing-tool/issues/17) | `payment_testing_go` | `declined_expired.json` / `declined_invalid_cvv.json` no longer decline |
| [io.paycross#871](https://github.com/paycross/io.paycross/issues/871) | `paycross-core` | a failed transaction can render `failure: null` |
| [payment-android-sdk#25](https://github.com/paycross/payment-android-sdk/issues/25) | `payment-android-sdk` | poll deadline reports `Recovery.RETRY` over a succeeded, liability-shifted payment |

## The run was interrupted by a ~10 h host sleep

2026-08-29 19:50Z → 2026-08-30 04:25Z. Both runners survived it and resumed on
their own; two cells were in flight and each recorded a **sleep artifact, not a
measurement** — iOS `decline_do_not_honor` (card typed ~9.5 h after its session
expired) and Android `airplane_during_challenge`. Both were rerun with
`--only … --all` on the same evidence roots.

One side effect worth carrying forward: `IosDriver` builds its console capture
as `log show --last <seconds>s` with the window measured from app launch. Every
cell in this run used 52–90 s except the one straddling the sleep, which used
**35354 s** and pulled ~10 h of simulator system log into a single cell's
`logs.txt`. A relaunch per cell, or a cap on the window, would bound it.
