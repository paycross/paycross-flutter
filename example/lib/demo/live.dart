import 'presets.dart';

/// The amount a Live smoke charges, in minor units. One of whatever
/// currency the tester picked.
///
/// Hardcoded, with no editor anywhere near it. A Live amount field is a
/// Live typo, and the difference between one euro and a hundred is one
/// keystroke.
///
/// **Changing it is one edit.** It used to be four: the charge body and the
/// confirmation dialog derived from this constant, but three pieces of copy
/// spelled the figure out by hand, so changing one meant the app quoted two
/// different numbers to the person about to spend the money. Every one of
/// those four now renders [liveSmokeAmountLabel], which is the only place
/// the figure is written for a human to read.
const int liveSmokeMinorUnits = 100;

/// The currency a Live smoke charges in until the tester picks another.
///
/// One of [currencies], because the dropdown that changes it is built from
/// that list. A value rather than a null, because the tile quotes an amount
/// before anything has been held for the session and there has to be
/// something to quote.
const String liveDefaultCurrency = 'EUR';

/// How each currency the Live form offers is written.
///
/// Three entries rather than a package: this app shows one amount in one of
/// three currencies, and `intl` would bring a locale question -- whose
/// separators, whose symbol placement -- that nobody here has an answer for.
const Map<String, String> _liveCurrencySymbols = <String, String>{
  'EUR': '€',
  'USD': r'$',
  'GBP': '£',
};

/// What a Live smoke costs, written the way the tester reads it.
///
/// The one place the figure is spelled out. Four pieces of copy quote it --
/// the tile's title, the tile's subtitle, Home's Live paragraph and the
/// confirmation dialog -- and all four call this, so they cannot say two
/// different numbers about the same charge.
///
/// All three of [currencies] are two-decimal, so dividing by 100 is right
/// for each of them. A code this map does not hold falls back to
/// `1.00 XXX`: unlovely, and honest, which is the trade worth making when
/// the alternative is an unknown currency printed under a euro sign.
String liveSmokeAmountLabel(String currency) {
  final amount = (liveSmokeMinorUnits / 100).toStringAsFixed(2);
  final symbol = _liveCurrencySymbols[currency];
  return symbol == null ? '$amount $currency' : '$symbol$amount';
}

/// Who a Live smoke charges.
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

/// The customer reference every Live smoke shares.
///
/// Stable rather than per-run, so repeat smokes land on one customer in the
/// back office instead of scattering across a new one each time.
const String liveSmokeCustomerReference = 'paycross_live_smoke';

/// The Live tile's title, and what it tells the person tapping it.
///
/// Functions rather than fields of [liveSmokePreset], because the tile is
/// drawn whether or not an identity is held and the preset cannot be built
/// without one. They take the currency for the same reason: the tile is on
/// screen before "Use for this session" has been pressed, and there it
/// quotes [liveDefaultCurrency].
String liveSmokeName(String currency) =>
    'Live smoke — ${liveSmokeAmountLabel(currency)} charge';

/// Deliberately worded so that it does not begin with one of the five
/// prefixes the matrix runner reads as "this build has no automation
/// define". Automation never runs Live, but the two preset sets are held
/// to one rule so they cannot diverge.
String liveSmokeExpectation(String currency) =>
    'A real card is charged ${liveSmokeAmountLabel(currency)} on the '
    'production merchant. Refund it in the back office straight afterwards.';

/// What a Live smoke mints, under the identity that was typed.
///
/// Built from the same `_body()` helper every sandbox preset uses, through
/// [liveBody]. One definition of this shape, not two: the last time this
/// app held two, one of them omitted the customer object the create schema
/// requires and answered 400 on the first tester's phone (PR #30).
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
/// record. A smoke that declines for either of those teaches the tester
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
String liveSmokeBody(LiveIdentity identity, String currency) => liveBody(
  amount: liveSmokeMinorUnits,
  currency: currency,
  email: identity.email,
  firstName: identity.firstName,
  lastName: identity.lastName,
  customerReference: liveSmokeCustomerReference,
);

/// The one tile Live mode offers, for the identity and the currency this
/// session holds.
Preset liveSmokePreset(LiveIdentity identity, String currency) => Preset(
  name: liveSmokeName(currency),
  body: liveSmokeBody(identity, currency),
  expected: liveSmokeExpectation(currency),
);
