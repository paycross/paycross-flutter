import Flutter
import PayCross
import PayCrossCore
import UIKit
import XCTest

@testable import paycross_flutter

/// Unit tests of the one thing the iOS half of the plugin decides: how a
/// native `PaymentResult` becomes the Pigeon type Dart receives.
///
/// NOTE: no CI job compiles or runs this target. The iOS job builds the example
/// app for the simulator, which compiles the plugin but not its tests. These
/// run from Xcode. They replace the untouched Flutter template test that shipped
/// here, which called `PaycrossFlutterPlugin().handle(...)` for a
/// `getPlatformVersion` method — a class name and a method that have never
/// existed in this plugin, since it speaks Pigeon rather than method channels.
class RunnerTests: XCTestCase {

    func testEveryRecoveryHasANonEmptyWireToken() {
        // The empty string is how both SDKs spell "the server said nothing",
        // which Dart reads as retry. No case may collapse to it.
        let every: [Recovery] = [
            .retry, .changeMethod, .restart, .contactSupport, .doNotRetry,
            .verifyBeforeRetry, .unrecognized("issuer_wants_a_phone_call"),
        ]

        for recovery in every {
            XCTAssertFalse(
                recovery.apiValue.isEmpty,
                "\(recovery) produced an empty wire token"
            )
        }
    }

    func testVerifyBeforeRetryCrossesAsItsOwnToken() {
        XCTAssertEqual(Recovery.verifyBeforeRetry.apiValue, "verify_before_retry")
    }

    func testAnUnknownRecoveryCrossesVerbatim() {
        // Dart re-parses this into RecoveryUnrecognized, so the server's own
        // string has to survive rather than collapsing to a known case.
        XCTAssertEqual(
            Recovery.unrecognized("issuer_wants_a_phone_call").apiValue,
            "issuer_wants_a_phone_call"
        )
    }

    func testCancellationCarriesTheAttemptItWalkedAwayFrom() {
        let pigeon = PaymentResult.cancelled(transactionID: "tx-3").toPigeon()

        XCTAssertEqual((pigeon as? PcCancelled)?.transactionId, "tx-3")
    }

    func testCancellationBeforeAnyTransactionCarriesNone() {
        let pigeon = PaymentResult.cancelled(transactionID: nil).toPigeon()

        XCTAssertNil((pigeon as? PcCancelled)?.transactionId)
    }

    func testFailureCarriesTheRecoveryToken() {
        let pigeon = PaymentResult.failed(
            transactionID: "tx-1",
            recovery: .verifyBeforeRetry
        ).toPigeon()

        XCTAssertEqual((pigeon as? PcFailure)?.recovery, "verify_before_retry")
        XCTAssertEqual((pigeon as? PcFailure)?.transactionId, "tx-1")
    }
}
