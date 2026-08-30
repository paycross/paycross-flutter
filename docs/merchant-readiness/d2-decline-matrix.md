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

Three of the eighteen cells are Android-only: the iOS simulator shares the
host's network and has no airplane mode (R6).

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

## The discovery cells, both platforms

Every `<any>` cell that ran on both platforms produced **the same label on
both**. There is no Android/iOS divergence anywhere in this dimension.

| cell | Android | iOS | agree |
|---|---|---|---|
| `completed_session_represented` | `result:success:<txn>` | `result:success:<txn>` | yes |
| `error_malformed_token` | `result:failure:restart:` (empty `<txn>`) | `result:failure:restart:` (empty `<txn>`) | yes |
| `session_expired_jwt` | `result:failure:restart:` (empty `<txn>`) | `result:failure:restart:` (empty `<txn>`) | yes |
| `timeout_provider_never_answers` | `result:failure:retry:<txn>` | `result:failure:retry:<txn>` | yes |
| `session_expired_server` | no label; payable sheet | no label; payable sheet | yes |
| `airplane_during_challenge` | `result:failure:retry:<txn>` | *(android only, R6)* | — |
| `airplane_during_polling` | `result:failure:retry:<txn>` | *(android only, R6)* | — |

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

| | |
|---|---|
| session | `01a0512f-186f-713d-8d87-3bf2bb8345d6` — completed |
| transaction | `fd3ea19c-2d7a-460d-a926-5ed8ab3f9ad1` — **succeeded** |
| `threeds_result` | authenticated, challenge, **`liability_shifted: true`**, eci 05 |
| SDK label | **`result:failure:retry:fd3ea19c-…`** |

`PaymentViewModel.pollStatus` swallows `IOException`/`HttpException` as
transient, runs out its 480 s deadline and emits
`PayCrossResult.Failure(transactionId, Recovery.RETRY)` — hardcoded. It is not
reporting an observed failure; it is reporting the absence of an answer as one.
`Recovery` has no member meaning "outcome unknown, verify before re-collecting",
and the SDK contradicts its own stated policy: `isRetryable`'s docstring says
unknown recoveries "fail closed", yet the one genuinely-unknown case fails open.

iOS is **suspected but unmeasurable** — the same shape is in
`PaymentFlowRunner.swift`, but R6 puts network cuts out of reach on a simulator.

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
