import 'dart:convert';

/// The currencies the editor offers.
///
/// The matrix runner renders an expected Pay-button amount with
/// `tree.format_amount_en_us`, whose symbol table holds exactly these three
/// (`tool/e2e/tree.py`). A fourth here would mint fine and then fail a cell
/// for a reason that has nothing to do with the SDK.
const List<String> currencies = <String>['EUR', 'USD', 'GBP'];

/// Stable customer for the card-on-file pair, so a saved card survives
/// across runs and across machines.
///
/// The backend mints a random customer when `customer.merchant_reference` is
/// absent, and it snapshots the saved-card list into a session **once, at
/// creation**. Both facts together mean the pay-with-saved-card session has
/// to be minted after the store has settled, against this same reference --
/// which is why the two presets are ordered and share the string.
const String cofCustomerReference = 'harness_cof_customer';

/// The top-level key that renders the "Save card for future use" checkbox.
///
/// Named rather than written wherever it is needed, because Live mode's
/// store-card tile sends this exact string too. The Live tile is this
/// scenario with a production merchant behind it, and a key that drifted
/// between the two -- a space, a spelling, a nesting -- would fail on the one
/// merchant nobody can retry cheaply, in a way no sandbox run reproduces.
///
/// A fragment of JSON rather than a map, because [_body] builds its output by
/// hand and `extraTopLevel` is spliced in as text. Its shape is pinned in
/// `presets_test.dart` against the bytes the automated matrix runs.
const String saveCardConfigOption =
    '"save_card_config": { "usage": "card_on_file" }';

/// The top-level key that snapshots the customer's stored cards into the
/// session, so the sheet can offer them.
///
/// Named for the same reason as [saveCardConfigOption], and shared with Live
/// mode's pay-with-saved-card tile.
const String savedCardsOption = '"saved_cards": { "show": "all" }';

/// The fake billing address every sandbox preset sends.
///
/// A default, and only a default: a Live body must not send it. Production
/// AVS and fraud rules exist to refuse exactly this, and a smoke test that
/// fails on a fabricated New York address has told you nothing about the
/// SDK.
const String _sandboxBilling = '''
      "billing": {
        "line1": "123 Main Street",
        "line2": "Apt 4B",
        "city": "New York",
        "state": "NY",
        "postal_code": "10001",
        "country": "US"
      }''';

String _body({
  required int amount,
  // The sandbox default, and spelled here rather than taken from
  // `live.dart`'s `liveDefaultCurrency`: that file imports this one, and the
  // two defaults are one value by coincidence rather than by rule. Every
  // sandbox preset below leaves it alone, so their bodies are the bytes they
  // always were -- which is what the automated matrix runs against.
  String currency = 'EUR',
  String? extraTopLevel,
  String? customer,
  String reference = 'DEMO-{{timestamp}}',
  String email = 'john.doe@example.com',
  String firstName = 'John',
  String lastName = 'Doe',
  String? phone = '+12025551234',
  String? billing = _sandboxBilling,
}) =>
    '''
{
  "amount": $amount,
  "currency": "$currency",
  "transaction_type": "sale",
  "merchant_reference": "$reference",
  "return_url": "https://merchant.example.com/payment/return",
  "success_url": "https://merchant.example.com/payment/success",${extraTopLevel == null ? '' : '\n  $extraTopLevel,'}
  "customer": {
    "email": ${jsonEncode(email)},
    "first_name": ${jsonEncode(firstName)},
    "last_name": ${jsonEncode(lastName)},${phone == null ? '' : '\n    "phone": ${jsonEncode(phone)},'}
    "merchant_reference": "${customer ?? 'CUST-{{timestamp}}'}"${billing == null ? '' : ',\n    "address": {\n$billing\n    }'}
  }
}''';

/// The body every scenario without special needs mints.
String defaultBody({int amount = 1000}) => _body(amount: amount);

/// Renders the checkbox that lets the shopper store the card.
final String cofStoreBody = _body(
  amount: 1000,
  extraTopLevel: saveCardConfigOption,
  customer: cofCustomerReference,
);

/// Snapshots the customer's stored cards into the session.
final String cofPaySavedBody = _body(
  amount: 1000,
  extraTopLevel: savedCardsOption,
  customer: cofCustomerReference,
);

/// The body "Verify credentials" mints and immediately abandons.
///
/// Built from the same helper as every preset, and that is the fix rather
/// than a tidy-up: this body used to be hand-written separately inside
/// `minter.dart`, omitted the `customer` object the create schema requires,
/// and answered 400 on the first tester's phone in demo-v0.1.0 build 26. Two
/// definitions of one shape drift; one cannot.
///
/// A smaller amount and its own `merchant_reference` prefix, so a verify
/// session abandoned in the sandbox is still tellable from a real demo run.
final String verifyProbeBody = _body(
  amount: 100,
  reference: 'DEMO-VERIFY-{{timestamp}}',
);

/// A body for an identity that is not the sandbox fake, with no billing
/// address.
///
/// Public because `live.dart` needs it and `_body` is private, and a second
/// copy of the helper in that file is precisely the drift PR #30 was about.
///
/// It takes the identity's three fields loose rather than the `LiveIdentity`
/// they come from, because that type lives in `live.dart` and `live.dart`
/// already imports this file -- naming it here would close a cycle that
/// nothing needs. The call site unpacks the identity instead.
///
/// The currency is required rather than defaulted, unlike every other
/// argument here: a Live body is minted from a currency the tester chose on
/// a dropdown, and a default would let a caller that forgot to pass it
/// charge in euros on a merchant that only takes pounds.
/// [extraTopLevel] is the one thing Live's three tiles disagree about. Null
/// is the plain smoke; the saved-card tiles pass [saveCardConfigOption] and
/// [savedCardsOption], which are the same two strings the sandbox presets
/// above send. Threaded into the same `_body` argument rather than spliced
/// on afterwards, so the sandbox pair and the Live pair cannot end up sending
/// differently-shaped JSON for one feature.
String liveBody({
  required int amount,
  required String currency,
  required String email,
  required String firstName,
  required String lastName,
  required String customerReference,
  String? extraTopLevel,
}) => _body(
  amount: amount,
  currency: currency,
  extraTopLevel: extraTopLevel,
  reference: 'LIVE-SMOKE-{{timestamp}}',
  customer: customerReference,
  email: email,
  firstName: firstName,
  lastName: lastName,
  // Both omitted, not faked, and for one reason. See `live.dart`.
  phone: null,
  billing: null,
);

/// A named scenario: what to mint, what should happen, and which card to type.
class Preset {
  const Preset({
    required this.name,
    required this.body,
    required this.expected,
    this.cardHint,
    this.hint,
  });

  final String name;

  /// The raw session body, with `{{timestamp}}` / `{{uuid}}` placeholders.
  final String body;

  /// What the person running it should see. Deliberately worded so that no
  /// expectation begins with one of the five prefixes the matrix runner
  /// reads as "this build has no automation define".
  final String expected;

  /// Which sandbox card to type, and which ACS button to press.
  final String? cardHint;

  /// Anything that must happen first.
  final String? hint;
}

/// The scenarios on Home, in the order they are worth running.
final List<Preset> demoPresets = <Preset>[
  Preset(
    name: 'Instant approve (no 3DS)',
    body: defaultBody(),
    expected: 'Approved with no 3-D Secure step at all.',
    cardHint: '4111 1111 1117 0000',
  ),
  Preset(
    name: 'Frictionless 3DS',
    body: defaultBody(),
    expected: 'Approved after a frictionless 3-D Secure check — no challenge.',
    cardHint: '4111 1111 1115 3063',
  ),
  Preset(
    name: '3DS challenge → approve',
    body: defaultBody(),
    expected: 'Approved after the challenge.',
    cardHint: '4111 1111 1115 3220, then tap approve on the sandbox ACS page',
  ),
  Preset(
    name: '3DS challenge → decline',
    body: defaultBody(),
    expected: 'Refused after the challenge — recovery do_not_retry.',
    cardHint:
        '4111 1111 1115 3220, then tap fraud_suspected on the sandbox ACS page',
  ),
  Preset(
    name: '3DS challenge → retryable decline',
    body: defaultBody(),
    // Verified on both platforms in the D0 matrix: a retryable recovery
    // re-arms the native sheet rather than returning, so the run only
    // finishes when the shopper cancels.
    expected:
        'The sheet re-arms for another attempt (recovery change_method). '
        'Cancel it to come back here.',
    cardHint:
        '4111 1111 1115 3220, then tap authentication_failed on the '
        'sandbox ACS page',
  ),
  Preset(
    name: 'Store card (COF)',
    body: cofStoreBody,
    expected: 'Approved, and the card is stored for $cofCustomerReference.',
    cardHint: '4111 1111 1117 0000, and tick "Save card for future use"',
    hint: 'Re-running this is safe: the same PAN returns already_existing.',
  ),
  Preset(
    name: 'Pay with saved card (COF)',
    body: cofPaySavedBody,
    expected: 'Charged the stored card without retyping it.',
    hint: 'Run "Store card (COF)" first, or the card list will be empty.',
  ),
  Preset(
    name: 'Google Pay (Android)',
    body: defaultBody(),
    // Two merchant-level attributes gate the wallet button and neither has
    // a per-session override, so this preset shows what the TEST merchant is
    // configured for -- it cannot turn the button on or off.
    expected:
        'Google Pay shows only when the TEST merchant has the wallet '
        'enabled. Its absence is merchant configuration, not a bug.',
  ),
];

/// What "Custom" opens the editor on: the ordinary body, and an expectation
/// that says the person running it is the one who knows what should happen.
final Preset customPreset = Preset(
  name: 'Custom',
  body: defaultBody(),
  expected: 'Whatever the edited body asks for.',
);
