import 'presets.dart';

/// The amount a Live smoke charges, in minor units. One euro.
///
/// Hardcoded, with no editor anywhere near it. A Live amount field is a
/// Live typo, and the difference between €1.00 and €100.00 is one keystroke.
const int liveSmokeMinorUnits = 100;

/// Who a Live smoke charges.
///
/// The sandbox presets send `john.doe@example.com` at a New York address,
/// which production AVS and fraud rules are built to refuse -- so a Live
/// smoke that reused them would fail for a reason that says nothing about
/// the SDK. This is an owner-designated internal identity instead: a real
/// name and a real internal email, on a charge that is refunded by hand
/// minutes later.
class LiveIdentity {
  const LiveIdentity({
    required this.firstName,
    required this.lastName,
    required this.email,
  });

  final String firstName;
  final String lastName;
  final String email;

  /// Whether any field is still the shipped placeholder.
  ///
  /// Any, not all: a half-finished edit is the shape a hurried change
  /// actually leaves behind, and half an identity on a real charge is no
  /// better than none.
  bool get isPlaceholder =>
      [firstName, lastName, email].any((f) => f.contains(_placeholder)) ||
      // The placeholder's own reserved TLD. An edit that replaced the local
      // part and left the domain behind is still an address nothing can
      // reach, and a receipt nobody receives is the same problem as no
      // identity at all.
      email.endsWith(_unroutableDomain);
}

const String _placeholder = 'REPLACE_ME';

/// The reserved TLD the shipped placeholder email sits on. `.invalid` is set
/// aside by RFC 2606 precisely so that it can never resolve.
const String _unroutableDomain = '.invalid';

/// **BLOCKING OWNER INPUT.** Replace all three fields with the internal
/// identity the owner designates, in one commit, and update **two** cases in
/// `live_test.dart` in the same one -- both go red the moment a real identity
/// lands here, and both are supposed to:
///
/// - *the shipped identity is a placeholder, and says so* -- its assertion
///   inverts, because [liveSmokeIdentityUnset] becomes false;
/// - *the refusal names the constant somebody has to change* -- it has to
///   expect a **null** [liveSmokeIdentityProblem] instead of a message.
///
/// The second one is the trap. Forcing [liveSmokeIdentityProblem] to stay
/// non-null is the repair that makes the suite green again, and it
/// permanently disables the Live tile while leaving a refusal on screen that
/// is no longer true.
///
/// Until then [liveSmokeIdentityUnset] is true and the Live tile refuses to
/// run, naming this constant on screen. That refusal is the feature: a
/// guessed name or an invented email reaching a production charge is the
/// one mistake in this app that cannot be taken back.
const LiveIdentity liveSmokeIdentity = LiveIdentity(
  firstName: 'REPLACE_ME',
  lastName: 'REPLACE_ME',
  email: 'REPLACE_ME@paycross.invalid',
);

/// True while nobody has supplied the identity.
bool get liveSmokeIdentityUnset => liveSmokeIdentity.isPlaceholder;

/// Why the Live smoke cannot run, or null if it can.
///
/// Returned as text rather than a bool because it is shown to a human on
/// the tile they just tapped, and "it does nothing" is what a broken build
/// looks like. It names the constant and the file so the person holding the
/// phone can say exactly what is missing.
String? get liveSmokeIdentityProblem => liveSmokeIdentityUnset
    ? 'Live smoke is not configured: liveSmokeIdentity in '
          'lib/demo/live.dart is still a placeholder. The owner supplies '
          'the internal name and email; nobody else invents one.'
    : null;

/// The customer reference every Live smoke shares.
///
/// Stable rather than per-run, so repeat smokes land on one customer in the
/// back office instead of scattering across a new one each time.
const String liveSmokeCustomerReference = 'paycross_live_smoke';

/// What a Live smoke mints.
///
/// Built from the same `_body()` helper every sandbox preset uses, through
/// [liveBody]. One definition of this shape, not two: the last time this
/// app held two, one of them omitted the customer object the create schema
/// requires and answered 400 on the first tester's phone (PR #30).
///
/// No billing address: `customer.address` is absent from the create schema's
/// `customer.required` list, which holds only `first_name`, `last_name` and
/// `email`, and the schema's own description calls the address a prefill. So
/// the minimal fields are all the API asks for, and a fabricated production
/// address is the AVS risk this whole constant exists to avoid.
final String liveSmokeBody = liveBody(
  amount: liveSmokeMinorUnits,
  email: liveSmokeIdentity.email,
  firstName: liveSmokeIdentity.firstName,
  lastName: liveSmokeIdentity.lastName,
  customerReference: liveSmokeCustomerReference,
);

/// The one tile Live mode offers.
final Preset liveSmokePreset = Preset(
  name: 'Live smoke — €1.00 charge',
  body: liveSmokeBody,
  expected:
      'A real card is charged €1.00 on the production merchant. Refund it '
      'in the back office straight afterwards.',
);
