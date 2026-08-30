/// True when built with `--dart-define=PAYCROSS_E2E=true`.
///
/// Off by default and invisible to merchants: it routes the app to the
/// automation screen and swaps that screen's human-readable outcome line for
/// the frozen contract label the matrix runner reads out of the
/// accessibility tree. Nothing else about the app changes.
///
/// `bool.fromEnvironment` accepts the literal `true` and nothing else, so
/// `PAYCROSS_E2E=1` leaves the contract off.
///
/// Every widget that behaves differently under this takes it as a
/// constructor argument defaulting to this constant, so one `flutter test`
/// run exercises both branches. The constant itself is read in exactly two
/// places: `main.dart`'s routing, and those defaults.
const bool kE2e = bool.fromEnvironment('PAYCROSS_E2E');
