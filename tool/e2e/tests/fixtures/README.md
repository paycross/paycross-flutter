# Tree fixtures

Real dumps, checked in so the matchers in `tool/e2e/tree.py` can be tested
without a device or a simulator. The Android files are byte-identical copies of
artifacts from the campaign's own E2E runs; the originals are kept in the
private campaign evidence tree, outside this repo. Every fixture here is
token-redacted — see the last section before adding another.

## `android-rearmed.uix`

`uiautomator dump` of the native SDK sheet after a declined submit, from the
2026-08-26 Android run (private campaign evidence).

It holds the whole re-armed screen, which is what makes it the fixture for the
neighbouring-node test: the banner `text="Payment failed. Please try again."`,
the Pay button `text="Pay €10.00"`, a bare `text="€10.00"` header node, and a
`content-desc="Pay with GPay"` row. An exact match on `text` is the only thing
that tells the second apart from the other two.

No session token appears in it: this is the sheet's own tree, so the example
app's token field is not in it.

## `android-result.uix`

`uiautomator dump` of the example app's own result screen, from the 2026-08-28
Android smoke run (private campaign evidence).

It predates the frozen label contract, so its outcome string is the legacy
`content-desc="Paid 1000 EUR — …"` rather than a `result:…` one — which is also
what a dump from a build made without `--dart-define=PAYCROSS_E2E` looks like.

As a `sheet_rearmed` negative it carries neither half of the Android
conjunction, so it cannot show that either half is required on its own. The
test drops the banner from `android-rearmed.uix` for that.

## `ios-source.xml`

**A composite, not one screen.** Assembled from several WebDriverAgent
`GET /source` captures so that one file exercises every matcher: the example's
result screen, the sheet's tagged controls, the challenge navigation bar and
two ACS outcome buttons all appear as siblings of one another.

Two consequences for anyone writing against it:

- `label_from_tree` and `sheet_rearmed` are **both** truthy on this file, by
  construction. A real tree is never both — the sheet is gone by the time the
  Dart label lands — so do not read a precedence between them off this fixture.
- `fraud_suspected` sits at `y="1402"` with `visible="false"` on a 402×874
  sheet. That is the real shape of the problem, not a typo: the
  `ISSUER DECLINES` group starts below the fold and WebKit keeps it in the tree
  with off-screen coordinates. It is here so that a driver preferring on-screen
  nodes has something to reject.

## Redaction

The example app's token field still holds the session token on the result
screen, on both platforms, so a dump of that screen is a live credential until
it is redacted. Both fixtures that reach it carry `[REDACTED-SESSION-TOKEN]` in
its place — `android-result.uix` was redacted at source, `ios-source.xml` was
written with the marker.

Before adding a fixture, run it through `evidence.redact` and confirm with
`grep -c 'eyJ'` that no JWT survives.
