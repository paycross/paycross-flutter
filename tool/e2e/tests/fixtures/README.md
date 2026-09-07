# Fixtures

Real captures, checked in so the matchers in `tool/e2e/tree.py` and the crash
attribution in `tool/e2e/verify.py` can be tested without a device or a
simulator. The Android files are copies of artifacts from the campaign's own
E2E runs, byte-identical but for the neutralised pids noted below; the
originals are kept in the private campaign evidence tree, outside this repo.
Every fixture here is token-redacted — see the last section before adding
another.

Every Android dump here except `android-result.uix` was re-taken on
**2026-09-07** from a debug build of the example against natives 0.8.0 / 0.7.0,
because the sheet publishes `paycross.*` identifiers now and the dumps that
predate them cannot show a matcher that reads one. `android-result.uix` was
deliberately left alone — see its own section.

**They are debug-build captures and that is load-bearing.** Compose writes a
`testTag` into `resource-id` only when the host app is debuggable. A dump taken
from a release build carries none of these identifiers, and a fixture re-taken
that way would silently delete every matcher's coverage.

## `android-rearmed.uix`

`uiautomator dump` of the native SDK sheet after a declined submit
(`4111111111150002`), against a session carrying `save_card_config`.

It holds the whole re-armed screen, which is what makes it the fixture for both
halves of `sheet_rearmed`: `paycross.errorBanner` with
`Payment failed. Please try again.` beside it, `paycross.amount` reading
`€10.00`, and `paycross.payButton` whose own text is EMPTY — the `Pay €10.00`
is on a child `TextView`, which is why the predicate reads the amount off the
header rather than off the button.

It also keeps the neighbouring-node shape the text matchers were tested on: a
bare `€10.00` header node, a `text="Pay €10.00"` and a
`content-desc="Pay with GPay"` row, all in one tree.

No session token appears in it: this is the sheet's own tree, so the example
app's token field is not in it. The declining PAN is in it, formatted, and is a
published sandbox test card.

## `android-result.uix`

`uiautomator dump` of the example app's own result screen, from the 2026-08-28
Android smoke run (private campaign evidence).

**Deliberately NOT re-recorded with the rest.** It predates the frozen label
contract, so its outcome string is the legacy `content-desc="Paid 1000 EUR — …"`
rather than a `result:…` one — which is also what a dump from a build made
without `--dart-define=PAYCROSS_E2E` looks like, and that is the whole thing two
tests read it for. Re-taking it from a current build would replace the only
capture of a pre-contract app and delete that coverage. It is the example's own
screen besides, so it carries no `paycross.*` identifier to bring up to date.

As a `sheet_rearmed` negative it carries neither half of the predicate, so it
cannot show that either half is required on its own; the tests drop one node at
a time from `android-rearmed.uix` for that.

## `android-uiautomation-crash.log`

The logcat block from the 2026-09-01 Android run, cell
`saved_card_3_challenge_save` (private campaign evidence) — a payment that
succeeded, with a confirmed transaction, that the runner failed anyway.

It is the driver's own `uiautomator dump` dying on a closed binder: thread
`UiAutomation`, `RuntimeException: Bad file descriptor`, and a stack that is
`BinderProxy` and accessibility frames from top to bottom. Two things make it
the fixture for `_attribute_fatal` rather than a hand-written string:

- it carries **no `Process:` line**, only `PID:`, which is what sent the old
  `_fatal_is_ours` down its conservative `return True`;
- it keeps the runtime's follow-on `Error reporting crash` block, whose frames
  reach `com.android.internal.os.RuntimeInit` and `java.lang.ThreadGroup`. Read
  as part of the first stack those would defeat the "nothing outside
  `android.`" test, so the fixture is also the proof that `_crash_block` stops
  where it should.

Pids are neutralised (`19931` → `11111`). Nothing else is changed. No token
appears in a crash block.

## `android-save-card-form.uix`, `android-saved-card-sheet.uix`, `android-saved-card-chosen.uix`

The card form with a save-card row on it, the sheet offering one stored card
with removal turned on, and that sheet after the row was chosen.

Three things they are the evidence for, each measured here rather than assumed:

* **`paycross.saveCard` is one node.** It carries the identifier, the checked
  state and the click all at once, because the tag is on the `toggleable` Row.
  The `Checkbox` inside it is not checkable at all. That is the reverse of what
  the fixture this replaces held, and it is why `save_card` stopped hunting the
  tree for anything two-state.
* **The saved-card list is a radio list**, not the `ExposedDropdownMenuBox` that
  arrived as its own popup window. There is no menu to open; every row is
  `paycross.savedCard.<uuid>` where it stands, and its bin is that plus
  `.delete`.
* **Choosing a card removes `paycross.cardNumber` and keeps `paycross.cvv`.**
  That pair is `select_saved_card`'s post-condition, and it replaced the
  `Enter CVV for ` prompt, which is copy and reads
  `Entrez le code de sécurité pour …` on a French sheet.

The stored card's uuid is a TEST customer's and is in the identifiers by
design — a row cannot be addressed without it.

## `android-cancel-dialog.uix`, `android-remove-dialog.uix`

The two SDK-drawn confirmations, and **the first proof that their identifiers
reach a dump at all**. Compose walks a node's parents looking for
`testTagsAsResourceId` and stops at the semantics root the node sits under; a
dialog is a window with a root of its own, so the flag set once on the sheet
left every dialog tag out of a dump while the instrumented tests — which read
every window — went on passing. Android SDK 0.8.0 sets it per window, and these
two dumps are the confirmation nobody had taken.

Each is the whole file: **a dialog arrives as its own window and the form behind
it is not in the tree**. That is why `dismiss_cancel` takes a second look for
the Pay button rather than expecting it beside the dialog, and why
`remove_saved_card` reads the row's identifier before it taps the bin.

`android-remove-dialog.uix` replaces `android-saved-card-menu.uix`, which was a
capture of the dropdown popup — a component that no longer exists.

## `ios-save-card-form.xml`, `ios-saved-card-sheet.xml`

WebDriverAgent `GET /source` of the card form with a save-card toggle on it,
and of the sheet offering one stored card with removal turned on. Both taken on
the simulator 2026-09-07 against PayCross 0.7.0.

`ios-save-card-form.xml` is the form BEFORE anything ticked the toggle, and it
holds the split `save_card` exists for: SwiftUI exposes one `Toggle` as two
`XCUIElementTypeSwitch` nodes, the named row (`paycross.saveCard`, x=20 w=362)
and an unnamed control inside it (x=321 w=63). Only the second responds to a
tap. The toggle sits at y=929 on an 874-tall screen, which is why it has to be
scrolled to.

`ios-saved-card-sheet.xml` is the measurement behind `IosDriver._picker_rows`,
and it records a **defect**: on 0.7.0 the picker publishes none of its own
identifiers. `.payCrossIdentifier(.savedCards)` on the `VStack` holding the
rows overrides the one set on each row and each bin, so three buttons come back
named `paycross.savedCards`:

| | x | width | label |
|---|---|---|---|
| the stored card's row | 20 | 318 | `Visa •••• 3063, 12/28` |
| its bin | 338 | 44 | `Remove card, Visa •••• 3063` |
| `Use a new card` | 20 | 362 | `Use a new card` |

The driver reads that geometry — left edge is a row, inset is a bin, last row
is `Use a new card` — rather than the labels, which are copy and are drawn in
French when the session asks.

## `ios-source.xml`

**A composite, not one screen.** Assembled so that one file exercises every
matcher: the example's result screen, the sheet's tagged controls, the
challenge navigation bar and two ACS outcome buttons all appear as siblings of
one another.

Its sheet half carries the values measured on the simulator 2026-09-07 —
`paycross.amount` labelled `Total, €10.00`, `paycross.errorBanner` carrying
`Payment failed. Please try again.` off-screen after a real decline, and the
Pay button. The challenge half is carried over from the previous composite with
its identifier brought up to the contract: no iOS challenge was driven in the
task that rewrote this file, so those two nodes are the one part of it that is
not a fresh measurement.

**The Pay button is named `paycross.sheet`, and that is not a typo.** SDK 0.7.0
puts the sheet's identifier on the group wrapping the form, and SwiftUI's outer
name overrides the one set on the pinned footer, so `paycross.payButton` is not
in the tree at all. The fixture records what the rig sees; a test derives the
corrected variant to prove `IosDriver._pay_button` prefers the contract when it
is there.

Three consequences for anyone writing against it:

- `label_from_tree` and `sheet_rearmed` are **both** truthy on this file, by
  construction. A real tree is never both — the sheet is gone by the time the
  Dart label lands — so do not read a precedence between them off this fixture.
- `fraud_suspected` sits at `y="1402"` with `visible="false"` on a 402×874
  sheet. That is the real shape of the problem, not a typo: the
  `ISSUER DECLINES` group starts below the fold and WebKit keeps it in the tree
  with off-screen coordinates. It is here so that a driver preferring on-screen
  nodes has something to reject.
- The example's own `Pay` button carries no identifier, so WDA falls its `name`
  back to the label. That is what `identifier_only` exists to tell apart from
  the SDK's own controls.

## Redaction

The example app's token field still holds the session token on the result
screen, on both platforms, so a dump of that screen is a live credential until
it is redacted. Both fixtures that reach it carry `[REDACTED-SESSION-TOKEN]` in
its place — `android-result.uix` was redacted at source, `ios-source.xml` was
written with the marker.

Before adding a fixture, run it through `evidence.redact` and confirm with
`grep -c 'eyJ'` that no JWT survives.
