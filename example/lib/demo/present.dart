import 'package:paycross_flutter/paycross_flutter.dart';

import '../e2e_label.dart';
import 'history.dart';
import 'outcome.dart';
import 'surface.dart';
import 'version_panel.dart';

/// How long the two bookkeeping steps after a payment get before the caller
/// stops waiting on them.
///
/// Neither is bounded by anything else: a platform channel with nothing
/// behind it never answers rather than failing. Without this the "Copy bug
/// report" button would simply never appear, and nobody would know why.
///
/// Deliberately not applied to the payment itself, which the plugin forbids
/// bounding -- a shorter deadline there abandons a live payment while the
/// native SDK keeps polling, and the card may still be charged.
const Duration bookkeepingTimeout = Duration(seconds: 5);

/// What came back from presenting one minted session.
///
/// Every field is what the screen showing it needs and nothing more: no
/// session token, no checkout URL, no response body. A payment that never
/// reached the sheet is the same shape as one that did, so a caller renders
/// both through [human] without telling them apart.
class PresentedRun {
  const PresentedRun({
    required this.human,
    this.label,
    this.transactionId,
    this.result,
  });

  /// What an ordinary person reads, from `outcome.dart`.
  final String human;

  /// The E2E automation contract's label, or null when the sheet threw
  /// something the contract has no word for.
  ///
  /// Null is load-bearing: inventing a label for an outcome nobody named
  /// would let a matrix cell pass on a run that never reached the sheet.
  final String? label;

  final String? transactionId;

  /// The result itself, or null when presenting threw.
  ///
  /// For a caller that has to branch on which outcome it was -- a storefront
  /// routes an approval to its thank-you page and everything else back to
  /// the checkout. A caller that only renders text reads [human] instead.
  final PayCrossResult? result;
}

/// Presents [sessionToken] and turns whatever happens into one value.
///
/// Shared by every screen that hands a session to the native sheet, so the
/// four outcomes, the integration error and the exception no contract names
/// are mapped once. Two of those arms exist for failures that used to leave
/// a screen waiting on a sheet that had already closed, and a second copy of
/// this mapping is a second place for one of them to go missing.
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
        // The whole point of the pending case: this is the id to reconcile
        // against, so it must reach History like any other.
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
    // The plugin documents that only a PayCrossIntegrationError escapes
    // `presentPayment`, and its own guard converts PlatformException. This
    // arm is for what that guard cannot see -- a MissingPluginException on a
    // build where the plugin did not register, say. Unhandled, it left the
    // screen waiting on the sheet for good, after a payment that may have
    // charged.
    //
    // The type only, never the message: this text is stored and copied, and
    // nothing promises what an unknown exception's message carries.
    return PresentedRun(
      human: 'The payment sheet failed unexpectedly: ${problem.runtimeType}',
    );
  }
}

/// Writes one run to History, and never lets that failure lose the outcome.
///
/// A payment has already happened by the time this runs, and it may have
/// taken money. A store that cannot be written costs a missing row; letting
/// it throw would cost the screen, which would sit waiting with no way to
/// tell a hang from a completed charge. The entry is returned either way,
/// because what the bug-report block quotes is held in memory rather than
/// read back out of the store.
///
/// The version read is guarded the same way and for the same reason: a throw
/// and a read that never answers are the same thing to the caller, and
/// "unknown" is the honest rendering of both.
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
  } catch (_) {
    // Nothing to say on screen: the entry is returned either way, so the
    // outcome card and its bug report render unchanged.
  }
  return entry;
}
