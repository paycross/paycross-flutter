import 'money.dart';
import 'presets.dart';

/// The amount every Live tile charges, in minor units. One of whatever
/// currency the tester picked.
///
/// Hardcoded, with no editor anywhere near it. A Live amount field is a
/// Live typo, and the difference between one euro and a hundred is one
/// keystroke.
///
/// **Changing it is one edit.** It was once several: the charge body and the
/// confirmation dialog derived from this constant, but the copy around them
/// spelled the figure out by hand, so changing one meant the app quoted two
/// different numbers to the person about to spend the money. Every site now
/// renders [liveSmokeAmountLabel], which is the only place the figure is
/// written for a human to read -- and three tiles would otherwise have
/// tripled the number of places to get it wrong.
const int liveSmokeMinorUnits = 100;

/// The currency every Live tile charges in until the tester picks another.
///
/// One of [currencies], because the dropdown that changes it is built from
/// that list. A value rather than a null, because the tile quotes an amount
/// before anything has been held for the session and there has to be
/// something to quote.
const String liveDefaultCurrency = 'EUR';

/// What a Live tile costs, written the way the tester reads it.
///
/// The one place the figure is spelled out. Every piece of copy quotes it --
/// each tile's title, each tile's subtitle, Home's Live paragraph and each
/// confirmation dialog -- and every one of them calls this, so they cannot
/// say two different numbers about the same charge.
///
/// Rendered by [formatMoney], the same function the result screen uses, so
/// the figure the tester agreed to and the figure they are told was charged
/// are written by one hand.
String liveSmokeAmountLabel(String currency) =>
    formatMoney(liveSmokeMinorUnits, currency);

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
/// All three charge the same amount, in the same currency, to the same
/// [liveSmokeCustomerReference]. The only thing they disagree about in the
/// body is one top-level key, which is what [liveExtraOption] is.
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

/// A tile's title, and what it tells the person tapping it.
///
/// Functions rather than fields of [livePreset], because the tiles are drawn
/// whether or not an identity is held and a preset cannot be built without
/// one. They take the currency for the same reason: the tiles are on screen
/// before "Use for this session" has been pressed, and there they quote
/// [liveDefaultCurrency].
String liveScenarioName(LiveScenario scenario, String currency) {
  final amount = liveSmokeAmountLabel(currency);
  return switch (scenario) {
    LiveScenario.smoke => 'Live smoke — $amount charge',
    LiveScenario.storeCard => 'Live — store card, $amount charge',
    LiveScenario.paySavedCard => 'Live — pay with saved card, $amount charge',
  };
}

/// What the tester should see, and what they owe afterwards.
///
/// Every one of them says Refund, because every one of them is real money
/// and the subtitle is the last thing read before the tap.
///
/// Deliberately worded so that none begins with one of the five prefixes the
/// matrix runner reads as "this build has no automation define". Automation
/// never runs Live, but the two preset sets are held to one rule so they
/// cannot diverge.
String liveScenarioExpectation(LiveScenario scenario, String currency) {
  final amount = liveSmokeAmountLabel(currency);
  return switch (scenario) {
    LiveScenario.smoke =>
      'A real card is charged $amount on the production merchant. Refund it '
          'in the back office straight afterwards.',
    LiveScenario.storeCard =>
      'A real card is charged $amount and stored on the production customer '
          'for the tile below. Tick "Save card for future use" in the sheet. '
          'Refund the charge in the back office straight afterwards.',
    LiveScenario.paySavedCard =>
      'A card stored on the production customer is charged $amount. Run '
          '"store card" first, or the list in the sheet is empty. Refund the '
          'charge in the back office straight afterwards.',
  };
}

/// What the confirmation dialog asks before the money moves.
///
/// Here rather than spelled out on Home, for the reason
/// [liveSmokeAmountLabel] is: this sentence and the tile's own are read
/// seconds apart by somebody deciding whether to spend, and two files
/// writing them is how they end up describing different tiles.
///
/// The smoke's question is the one that shipped, unchanged. The other two
/// add a sentence, because "this will charge a real card 1.00" is not the
/// whole truth about a tile that also leaves a card on file.
String liveConfirmQuestion(LiveScenario scenario, String currency) {
  final extra = switch (scenario) {
    LiveScenario.smoke => '',
    LiveScenario.storeCard =>
      ' It also stores the card on the production customer.',
    LiveScenario.paySavedCard =>
      ' It charges a card already stored on the production customer.',
  };
  return 'This will charge a real card ${liveSmokeAmountLabel(currency)}.'
      '$extra Continue?';
}

/// What a tile mints, under the identity that was typed.
///
/// Built from the same `_body()` helper every sandbox preset uses, through
/// [liveBody]. One definition of this shape, not two: the last time this
/// app held two, one of them omitted the customer object the create schema
/// requires and answered 400 on the first tester's phone (PR #30). The
/// saved-card tiles are the same rule again -- they differ from the smoke by
/// one argument, not by a body of their own.
///
/// No billing address and no phone number. The create schema's
/// `customer.required` list holds only `first_name`, `last_name` and
/// `email`; `address` is additionally nullable and its own description
/// calls it a prefill. So the minimal fields are all the API asks for.
///
/// Both omissions are the same decision. A fabricated production address is
/// the AVS risk this whole path exists to avoid, and the phone the sandbox
/// presets carry -- `+12025551234`, the reserved fictional Washington-DC
/// 555 range -- is a fabricated contact detail of the same class, scored by
/// the same fraud engines, on a real charge from a European device. It would
/// also write a wrong number onto a real person's production customer
/// record. A charge that declines for either of those teaches the tester
/// nothing about the SDK, which is the failure this design was written to
/// prevent.
///
/// If a real internal phone number is ever wanted, it is a third typed
/// field beside the name and the email -- never an inherited sandbox
/// default.
///
/// The currency is passed in rather than defaulted here, so that the body
/// and the copy the tester read before pressing Continue take the same
/// value from the same caller.
String liveScenarioBody(
  LiveScenario scenario,
  LiveIdentity identity,
  String currency,
) => liveBody(
  amount: liveSmokeMinorUnits,
  currency: currency,
  email: identity.email,
  firstName: identity.firstName,
  lastName: identity.lastName,
  customerReference: liveSmokeCustomerReference,
  extraTopLevel: liveExtraOption(scenario),
);

/// One Live tile, for the identity and the currency this session holds.
///
/// What `RunScreen` is handed and what History records, so the three strings
/// have to be the ones belonging to the tile that was tapped: a saved-card
/// charge filed under the smoke's name is a charge nobody can tell from the
/// other two afterwards.
Preset livePreset(
  LiveScenario scenario,
  LiveIdentity identity,
  String currency,
) => Preset(
  name: liveScenarioName(scenario, currency),
  body: liveScenarioBody(scenario, identity, currency),
  expected: liveScenarioExpectation(scenario, currency),
);
