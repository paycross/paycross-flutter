import 'presets.dart';

/// The amount a Live smoke charges, in minor units. One euro.
///
/// Hardcoded, with no editor anywhere near it. A Live amount field is a
/// Live typo, and the difference between one euro and a hundred is one
/// keystroke.
///
/// **Changing it is four edits, not one.** The charge body and the
/// confirmation dialog derive from this constant, but three pieces of copy
/// spell the figure out by hand -- [liveSmokeName], [liveSmokeExpectation],
/// and Home's Live paragraph. Change one and the app quotes two different
/// numbers to the person about to spend the money. The README's Live mode
/// section says the same thing to the same reader.
const int liveSmokeMinorUnits = 100;

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
/// Constants rather than fields of [liveSmokePreset], because the tile is
/// drawn whether or not an identity is held and the preset cannot be built
/// without one.
const String liveSmokeName = 'Live smoke — €1.00 charge';

/// Deliberately worded so that it does not begin with one of the five
/// prefixes the matrix runner reads as "this build has no automation
/// define". Automation never runs Live, but the two preset sets are held
/// to one rule so they cannot diverge.
const String liveSmokeExpectation =
    'A real card is charged €1.00 on the production merchant. Refund it '
    'in the back office straight afterwards.';

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
/// the same fraud engines, on a EUR charge from a European device. It would
/// also write a wrong number onto a real person's production customer
/// record. A smoke that declines for either of those teaches the tester
/// nothing about the SDK, which is the failure this design was written to
/// prevent.
///
/// If a real internal phone number is ever wanted, it is a third typed
/// field beside the name and the email -- never an inherited sandbox
/// default.
String liveSmokeBody(LiveIdentity identity) => liveBody(
  amount: liveSmokeMinorUnits,
  email: identity.email,
  firstName: identity.firstName,
  lastName: identity.lastName,
  customerReference: liveSmokeCustomerReference,
);

/// The one tile Live mode offers, for the identity this session holds.
Preset liveSmokePreset(LiveIdentity identity) => Preset(
  name: liveSmokeName,
  body: liveSmokeBody(identity),
  expected: liveSmokeExpectation,
);
