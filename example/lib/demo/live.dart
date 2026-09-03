import 'dart:convert';

import 'money.dart';
import 'presets.dart';
import 'surface.dart';

/// What the three default Live bodies charge, in minor units.
///
/// A default rather than a fixture. It was hardcoded with no editor near it,
/// on the reasoning that a Live amount field is a Live typo -- and the
/// workaround that grew out of it was a per-session currency picker in
/// Settings, which the owner called lazy. The amount and the currency are
/// now fields of the preset body like every other field, edited on the same
/// screen and saved in the same store.
///
/// What replaced the old protection is that nothing quotes a constant any
/// more. Every figure a human reads before spending -- the tile's title, the
/// confirmation dialog -- is rendered from the body that is about to be
/// minted, by [liveBodyAmountLabel]. An edited amount cannot be quoted
/// wrongly, because there is no second place holding the old one.
const int liveSmokeMinorUnits = 100;

/// The currency the three default Live bodies charge in.
///
/// One of [currencies], because the editor's dropdown is built from that
/// list. A default and nothing more: the currency a run actually charges in
/// is whatever the body says, and the body is editable and saveable.
const String liveDefaultCurrency = 'EUR';

/// What a Live body will actually charge, or null if this build cannot read
/// it.
///
/// Read off the body rather than off a constant, and that is the whole of
/// how the copy stays honest now that the amount is editable: the tile
/// title and the confirmation dialog are rendered from the very string that
/// is about to be minted, so there is no second place holding a stale
/// figure to disagree with it.
///
/// Null rather than a guess when the body does not parse or carries no
/// amount. A saved Live body cannot be in that state -- the editor refuses
/// to save one -- but a row written by a newer build could be, and a
/// confirmation dialog that quoted a made-up figure over a real charge is
/// the one failure worth being loud about. Callers refuse the run.
({int amount, String currency})? liveBodyMoney(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, Object?>) return null;
    final amount = decoded['amount'];
    final currency = decoded['currency'];
    if (amount is! int || currency is! String) return null;
    return (amount: amount, currency: currency);
  } on FormatException {
    return null;
  }
}

/// What a Live body charges, written the way the tester reads it, or null.
///
/// Rendered by [formatMoney], the same function the result screen uses, so
/// the figure the tester agreed to and the figure they are told was charged
/// are written by one hand.
String? liveBodyAmountLabel(String body) {
  final money = liveBodyMoney(body);
  return money == null ? null : formatMoney(money.amount, money.currency);
}

/// Who a Live charge is made under.
///
/// Typed on the phone, beside the production credentials, and held with
/// exactly their lifetime: in memory, never in a store, gone when the app
/// is and gone the moment the app goes back to Test. It was a compile-time
/// constant until 2026-09-01; the owner's decision was that a tester typing
/// it satisfies "a human chooses this, never an agent" just as well as an
/// owner's commit did, without the placeholder machinery.
///
/// The sandbox presets send `john.doe@example.com` at a New York address,
/// which production AVS and fraud rules are built to refuse -- so a Live
/// smoke that reused them would fail for a reason that says nothing about
/// the SDK.
class LiveIdentity {
  const LiveIdentity({
    required this.firstName,
    required this.lastName,
    required this.email,
  });

  /// The identity in what a human typed, or null if what they typed is not
  /// one.
  ///
  /// The two rules live in [liveNameProblem] and [liveEmailProblem] and are
  /// consulted here rather than repeated, so the reason a field shows and
  /// the reason this returns null cannot say different things.
  // One line, because `dart format` puts it on one: it fits in 80 columns
  // and the gate below promises `0 changed`.
  static LiveIdentity? parse({required String name, required String email}) {
    if (liveNameProblem(name) != null) return null;
    if (liveEmailProblem(email) != null) return null;
    final trimmed = name.trim();
    // The last space, not the first: a middle name or an initial belongs
    // to the given name. Safe unchecked because [liveNameProblem] has
    // already refused a trimmed string with no space in it, and a trimmed
    // string cannot begin or end with one -- so both halves are non-empty.
    final split = trimmed.lastIndexOf(' ');
    return LiveIdentity(
      firstName: trimmed.substring(0, split).trim(),
      lastName: trimmed.substring(split + 1),
      email: email.trim(),
    );
  }

  final String firstName;
  final String lastName;
  final String email;
}

/// Why what was typed is not a name, or null if it is one.
///
/// Returned as text rather than a bool because it is shown on the field it
/// is about. The create schema's `customer.required` list holds
/// `first_name` and `last_name` separately, so one word cannot be split
/// into a body the API will accept.
String? liveNameProblem(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return 'A name is required.';
  if (!trimmed.contains(' ')) {
    return 'A first and a last name — the charge needs both.';
  }
  return null;
}

/// Why what was typed is not an email address, or null if it is one.
///
/// One rule: an `@`. Anything stricter refuses addresses that are real --
/// this is a receipt for a charge on an internal person, typed by that
/// person or by a colleague who knows the address, and a validator that
/// second-guesses them costs a smoke run and proves nothing.
String? liveEmailProblem(String email) {
  final trimmed = email.trim();
  if (trimmed.isEmpty) return 'An email address is required.';
  if (!trimmed.contains('@')) return 'An email address needs an @.';
  return null;
}

/// The customer reference every Live tile shares.
///
/// Stable rather than per-run, so repeat runs land on one customer in the
/// back office instead of scattering across a new one each time.
///
/// Shared by all three tiles, and that is what makes the saved-card pair
/// work at all. The backend mints a random customer when
/// `customer.merchant_reference` is absent, and it snapshots the saved-card
/// list into a session **once, at creation**. A card stored under one
/// reference can never be offered by a session created under another, so a
/// per-tile reference would be a store tile whose card nothing can ever
/// spend -- across runs, across sessions and across devices.
const String liveSmokeCustomerReference = 'paycross_live_smoke';

/// One of the three things a Live session can do.
///
/// An enum with the copy hanging off it, rather than three tiles pasted
/// beside each other on Home. Every rung a Live run climbs -- the identity
/// and credential check, the confirmation dialog, the endpoints and currency
/// sampled at one instant, the busy guard -- is one piece of code that all
/// three go through, and a copied tile is how one of them ends up guarding
/// two runs and another guarding one.
///
/// All three *default* to the same amount and currency, and all three name
/// the same [liveSmokeCustomerReference]. The only thing their default
/// bodies disagree about is one top-level key, which is what
/// [liveExtraOption] is. What any of them actually charges after somebody
/// has edited and saved it is whatever that body says.
enum LiveScenario {
  /// A plain 1.00 sale. What Live mode was when it had one tile, and its
  /// body is unchanged to the byte.
  smoke,

  /// The same sale, asking the sheet to offer "Save card for future use".
  /// The card lands on the production customer, for [paySavedCard] to spend.
  storeCard,

  /// The same sale, with the cards already stored on that customer offered
  /// in the sheet instead of a keypad.
  paySavedCard,
}

/// What a tile adds to the smoke body, or null for the smoke itself.
///
/// The two strings come from `presets.dart`, where the sandbox saved-card
/// presets send them. These tiles are those scenarios with a production
/// merchant behind them, and a key spelled differently here would fail on
/// the one merchant nobody can retry cheaply -- while every sandbox run
/// carried on passing.
String? liveExtraOption(LiveScenario scenario) => switch (scenario) {
  LiveScenario.smoke => null,
  LiveScenario.storeCard => saveCardConfigOption,
  LiveScenario.paySavedCard => savedCardsOption,
};

/// What a saved edit to one of these tiles is filed under.
///
/// Words a maintainer typed rather than the tile's name, for the reason
/// every built-in id is: the name is copy and gets re-worded, and an edit
/// filed under a name would be lost the day somebody improves the wording.
///
/// They live in the Live half of the preset store and can never collide
/// with a sandbox id, because the two halves are separate keys rather than
/// one namespace being careful.
String liveScenarioId(LiveScenario scenario) => switch (scenario) {
  LiveScenario.smoke => 'live-smoke',
  LiveScenario.storeCard => 'live-store-card',
  LiveScenario.paySavedCard => 'live-pay-saved',
};

/// The widget key the tile carries on Home.
///
/// Named here rather than written on the widget, so that a test taps the
/// tile a scenario draws rather than a string that happens to match. The
/// smoke keeps the key it shipped with: the cases written against it are
/// still about the tile they were written for.
String liveTileKey(LiveScenario scenario) => switch (scenario) {
  LiveScenario.smoke => 'liveSmokeTile',
  LiveScenario.storeCard => 'liveStoreCardTile',
  LiveScenario.paySavedCard => 'liveSavedCardTile',
};

/// A tile's name, without the figure it charges.
///
/// The figure moved out of the name when the amount became editable: a name
/// is what History files a run under and what the editor's title bar says,
/// and a name carrying a figure would be a name that lies the moment
/// somebody saves a different amount. [liveTileTitle] puts the two together
/// for the tile, reading the money off the body.
String liveScenarioName(LiveScenario scenario) => switch (scenario) {
  LiveScenario.smoke => 'Live smoke',
  LiveScenario.storeCard => 'Live — store card',
  LiveScenario.paySavedCard => 'Live — pay with saved card',
};

/// What a Live tile is called on Home: its name, and what it will charge.
///
/// The money comes from the body about to be minted rather than from a
/// constant, so an edited tile quotes its own figure. A body this build
/// cannot read falls back to the name alone -- the tile refuses to run at
/// all in that state, and a title inventing an amount would be worse than a
/// title that is merely short.
String liveTileTitle(String name, String body) {
  final amount = liveBodyAmountLabel(body);
  return amount == null ? name : '$name — $amount charge';
}

/// What the tester should see, and what they owe afterwards.
///
/// Every one of them says Refund, because every one of them is real money
/// and the subtitle is the last thing read before the tap.
///
/// No figure in any of them: the title above already quotes what this body
/// charges, and a subtitle repeating a constant is exactly the second place
/// that used to be able to disagree with it.
///
/// Deliberately worded so that none begins with one of the five prefixes the
/// matrix runner reads as "this build has no automation define". Automation
/// never runs Live, but the two preset sets are held to one rule so they
/// cannot diverge.
String liveScenarioExpectation(LiveScenario scenario) => switch (scenario) {
  LiveScenario.smoke =>
    'A real card is charged the amount above on the production merchant. '
        'Refund it in the back office straight afterwards.',
  LiveScenario.storeCard =>
    'A real card is charged and stored on the production customer for the '
        'tile below. Tick "Save card for future use" in the sheet. Refund '
        'the charge in the back office straight afterwards.',
  LiveScenario.paySavedCard =>
    'A card stored on the production customer is charged. Run "store card" '
        'first, or the list in the sheet is empty. Refund the charge in the '
        'back office straight afterwards.',
};

/// What a tile somebody made in Live tells the person tapping it.
///
/// Its own sentence rather than the sandbox one. A body somebody typed is
/// still a real charge, and "whatever the edited body asks for" is not what
/// a tester needs to read above a production Continue button.
const String liveCustomExpectation =
    'A body you saved is charged on the production merchant. Refund it in '
    'the back office straight afterwards.';

/// What the confirmation dialog asks before the money moves.
///
/// Built from the body that is about to be minted, not from the tile that
/// was tapped. That is what makes it true of a preset somebody edited, and
/// of one they made from scratch: the amount, the currency and the two
/// saved-card sentences are all read out of the very bytes the minter will
/// send, so there is nothing here that can be stale.
///
/// [surface] adds one more sentence, and only for the web checkout. Where
/// the money is about to be spent is the question this dialog asks; *which
/// application is about to ask for the card* is part of the answer, and
/// somebody who taps Continue expecting a sheet and gets a browser will
/// wonder whether they tapped the wrong thing. Defaulted to the sheet, so
/// every call written before the surface existed asks exactly what it asked.
///
/// A body this build cannot read is not asked about at all -- callers refuse
/// the run before reaching here -- so the figure below is never invented.
String liveConfirmQuestion(
  String body, {
  PaymentSurface surface = PaymentSurface.sdkSheet,
}) {
  final amount =
      liveBodyAmountLabel(body) ?? 'an amount this build cannot read';
  final decoded = _decode(body);
  final extra = <String>[
    if (decoded?.containsKey('save_card_config') ?? false)
      ' It also stores the card on the production customer.',
    if (decoded?.containsKey('saved_cards') ?? false)
      ' It charges a card already stored on the production customer.',
  ].join();
  final where = switch (surface) {
    PaymentSurface.sdkSheet => '',
    PaymentSurface.webCheckout =>
      ' It opens in your browser instead of the app.',
  };
  return 'This will charge a real card $amount.$extra$where Continue?';
}

/// Why this body must not be minted on production, or null.
///
/// One rule, and it is the one the sandbox presets exist on the other side
/// of: the fake New York billing address. Production AVS and fraud rules are
/// built to refuse exactly that, and a smoke that declines because of one
/// has told the tester nothing about the SDK.
///
/// A refusal rather than a quiet strip. The raw body is the source of truth
/// on the editor screen, and silently deleting a line somebody typed is how
/// a tool stops being trustworthy -- so Run and Save go dead with this
/// sentence beside them, and the person decides.
///
/// Checked where the human is, which is why nothing downstream repeats it:
/// Save is the only way a body reaches the Live half of the store, so a
/// saved Live body cannot carry an address.
String? liveBodyProblem(String body) {
  final customer = _decode(body)?['customer'];
  if (customer is Map<String, Object?> && customer.containsKey('address')) {
    return 'A Live body must not carry the sandbox billing address — '
        'production fraud rules refuse a fabricated one.';
  }
  return null;
}

/// A decoded body, or null if it is not a JSON object.
Map<String, Object?>? _decode(String body) {
  try {
    final decoded = jsonDecode(body);
    return decoded is Map<String, Object?> ? decoded : null;
  } on FormatException {
    return null;
  }
}

/// What one of the three tiles mints before anybody has edited it.
///
/// Built from the same `_body()` helper every sandbox preset uses, through
/// [liveBody]. One definition of this shape, not two: the last time this
/// app held two, one of them omitted the customer object the create schema
/// requires and answered 400 on the first tester's phone (PR #30). The
/// saved-card tiles are the same rule again -- they differ from the smoke by
/// one argument, not by a body of their own.
///
/// No identity, no billing address and no phone number.
///
/// The identity is left out because a preset outlives the session the name
/// and address were typed for. [withLiveIdentity] puts them in at the
/// moment of minting, which is where they were always put -- the change is
/// that they are no longer baked into a string anything could store.
///
/// The address and the phone are left out for the older reason. The create
/// schema's `customer.required` list holds only `first_name`, `last_name`
/// and `email`; `address` is additionally nullable and its own description
/// calls it a prefill. A fabricated production address is the AVS risk this
/// whole path exists to avoid, and the phone the sandbox presets carry --
/// `+12025551234`, the reserved fictional Washington-DC 555 range -- is a
/// fabricated contact detail of the same class, scored by the same fraud
/// engines, on a real charge from a European device. It would also write a
/// wrong number onto a real person's production customer record. A charge
/// that declines for either of those teaches the tester nothing about the
/// SDK, which is the failure this design was written to prevent.
///
/// If a real internal phone number is ever wanted, it is a third typed
/// field beside the name and the email -- never an inherited sandbox
/// default.
String liveDefaultBody(LiveScenario scenario) => liveBody(
  amount: liveSmokeMinorUnits,
  currency: liveDefaultCurrency,
  customerReference: liveSmokeCustomerReference,
  extraTopLevel: liveExtraOption(scenario),
);

/// The three Live tiles as they ship, before anybody edits them.
///
/// Presets like the sandbox ones, with stable ids, so the same store and the
/// same editor serve both modes. What makes them Live is which half of the
/// store their overrides are kept in, not a different type.
///
/// `cardHint` is deliberately null on all three: nothing about a sandbox
/// card belongs on a production tile.
final List<Preset> liveDefaultPresets = <Preset>[
  for (final scenario in LiveScenario.values)
    Preset(
      id: liveScenarioId(scenario),
      name: liveScenarioName(scenario),
      body: liveDefaultBody(scenario),
      expected: liveScenarioExpectation(scenario),
    ),
];

/// Puts the identity typed in Settings into the body about to be minted.
///
/// At mint time, and nowhere else. A [LiveIdentity] is a real person's name
/// and email address, held in memory for exactly one session on purpose; a
/// preset is a row on the phone that outlives it. Splicing here is what lets
/// the body be saved and the identity not be.
///
/// The customer object is created if the body has no usable one, rather than
/// the identity being dropped. A body without those three fields is the 400
/// PR #30 was written about, and a splice that quietly did nothing would
/// reproduce it on the one merchant nobody can retry cheaply.
///
/// Re-encoded with the two-space indent the editor writes, so a body that
/// goes through here reads the same as one that came out of the editor. Key
/// order changes -- `merchant_reference` was written first in the template
/// and the three identity fields land after it -- which the API does not
/// care about and a person reading a bug report does not either.
String withLiveIdentity(String body, LiveIdentity identity) {
  final decoded = _decode(body) ?? <String, Object?>{};
  final existing = decoded['customer'];
  final customer = existing is Map<String, Object?>
      ? existing
      : <String, Object?>{};
  customer['email'] = identity.email;
  customer['first_name'] = identity.firstName;
  customer['last_name'] = identity.lastName;
  decoded['customer'] = customer;
  return const JsonEncoder.withIndent('  ').convert(decoded);
}
