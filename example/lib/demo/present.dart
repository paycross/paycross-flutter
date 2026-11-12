import 'package:paycross_flutter/paycross_flutter.dart';

import '../e2e_label.dart';
import 'history.dart';
import 'outcome.dart';
import 'surface.dart';
import 'version_panel.dart';

const Duration bookkeepingTimeout = Duration(seconds: 5);

class PresentedRun {
  const PresentedRun({
    required this.human,
    this.label,
    this.transactionId,
    this.result,
  });

  final String human;

  final String? label;

  final String? transactionId;

  final PayCrossResult? result;
}

Future<PresentedRun> presentSession(
  Future<PayCrossResult> Function(String sessionToken) present,
  String sessionToken,
) async {
  try {
    final paid = await present(sessionToken);
    return PresentedRun(
      human: humanOutcome(paid),
      label: labelForResult(paid),
      transactionId: switch (paid) {
        PayCrossSuccess(:final transactionId) => transactionId,
        PayCrossFailure(:final transactionId) => transactionId,
        PayCrossPending(:final transactionId) => transactionId,
        PayCrossCancelled(:final transactionId) => transactionId,
      },
      result: paid,
    );
  } on PayCrossIntegrationError catch (problem) {
    return PresentedRun(
      human: humanError(problem),
      label: labelForError(problem),
    );
  } catch (problem) {
    return PresentedRun(
      human: 'The payment sheet failed unexpectedly: ${problem.runtimeType}',
    );
  }
}

Future<HistoryEntry> recordRun({
  required HistoryStore history,
  required Future<DemoVersions> Function() readVersions,
  required String scenario,
  required String sessionId,
  required String? transactionId,
  required String outcome,
  bool live = false,
  String surface = sdkSurfaceName,
}) async {
  DemoVersions versions;
  try {
    versions = await readVersions().timeout(bookkeepingTimeout);
  } catch (_) {
    versions = unknownVersions;
  }
  final entry = HistoryEntry(
    at: DateTime.now(),
    presetName: scenario,
    sessionId: sessionId,
    transactionId: transactionId,
    outcome: outcome,
    demoVersion: versions.demo,
    pluginVersion: versions.plugin,
    nativeSdkVersion: versions.nativeSdk,
    live: live,
    surface: surface,
  );
  try {
    await history.append(entry).timeout(bookkeepingTimeout);
  } catch (_) {}
  return entry;
}
