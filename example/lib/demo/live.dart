import 'dart:convert';

import 'money.dart';
import 'presets.dart';
import 'surface.dart';

const int liveSmokeMinorUnits = 100;

const String liveDefaultCurrency = 'EUR';

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

String? liveBodyAmountLabel(String body) {
  final money = liveBodyMoney(body);
  return money == null ? null : formatMoney(money.amount, money.currency);
}

class LiveIdentity {
  const LiveIdentity({
    required this.firstName,
    required this.lastName,
    required this.email,
  });

  static LiveIdentity? parse({required String name, required String email}) {
    if (liveNameProblem(name) != null) return null;
    if (liveEmailProblem(email) != null) return null;
    final trimmed = name.trim();
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

String? liveNameProblem(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return 'A name is required.';
  if (!trimmed.contains(' ')) {
    return 'A first and a last name — the charge needs both.';
  }
  return null;
}

String? liveEmailProblem(String email) {
  final trimmed = email.trim();
  if (trimmed.isEmpty) return 'An email address is required.';
  if (!trimmed.contains('@')) return 'An email address needs an @.';
  return null;
}

const String liveSmokeCustomerReference = 'paycross_live_smoke';

enum LiveScenario { smoke, storeCard, paySavedCard }

String? liveExtraOption(LiveScenario scenario) => switch (scenario) {
  LiveScenario.smoke => null,
  LiveScenario.storeCard => saveCardConfigOption,
  LiveScenario.paySavedCard => savedCardsOption,
};

String liveScenarioId(LiveScenario scenario) => switch (scenario) {
  LiveScenario.smoke => 'live-smoke',
  LiveScenario.storeCard => 'live-store-card',
  LiveScenario.paySavedCard => 'live-pay-saved',
};

String liveTileKey(LiveScenario scenario) => switch (scenario) {
  LiveScenario.smoke => 'liveSmokeTile',
  LiveScenario.storeCard => 'liveStoreCardTile',
  LiveScenario.paySavedCard => 'liveSavedCardTile',
};

String liveScenarioName(LiveScenario scenario) => switch (scenario) {
  LiveScenario.smoke => 'Live smoke',
  LiveScenario.storeCard => 'Live — store card',
  LiveScenario.paySavedCard => 'Live — pay with saved card',
};

String liveTileTitle(String name, String body) {
  final amount = liveBodyAmountLabel(body);
  return amount == null ? name : '$name — $amount charge';
}

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

const String liveCustomExpectation =
    'A body you saved is charged on the production merchant. Refund it in '
    'the back office straight afterwards.';

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

String? liveBodyProblem(String body) {
  final customer = _decode(body)?['customer'];
  if (customer is Map<String, Object?> && customer.containsKey('address')) {
    return 'A Live body must not carry the sandbox billing address — '
        'production fraud rules refuse a fabricated one.';
  }
  return null;
}

Map<String, Object?>? _decode(String body) {
  try {
    final decoded = jsonDecode(body);
    return decoded is Map<String, Object?> ? decoded : null;
  } on FormatException {
    return null;
  }
}

String liveDefaultBody(LiveScenario scenario) => liveBody(
  amount: liveSmokeMinorUnits,
  currency: liveDefaultCurrency,
  customerReference: liveSmokeCustomerReference,
  extraTopLevel: liveExtraOption(scenario),
);

final List<Preset> liveDefaultPresets = <Preset>[
  for (final scenario in LiveScenario.values)
    Preset(
      id: liveScenarioId(scenario),
      name: liveScenarioName(scenario),
      body: liveDefaultBody(scenario),
      expected: liveScenarioExpectation(scenario),
    ),
];

String withLiveIdentity(String body, LiveIdentity identity) {
  final decoded = _decode(body) ?? <String, Object?>{};
  final customer = customerFor(decoded);
  customer['email'] = identity.email;
  customer['first_name'] = identity.firstName;
  customer['last_name'] = identity.lastName;
  return const JsonEncoder.withIndent('  ').convert(decoded);
}
