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

    func testAnAppearanceCrossesEveryFieldAndTruncatesColoursSafely() {
        // The colours arrive as unsigned packed ARGB in an Int64. An exact
        // UInt32(_:) traps at runtime on anything outside 0...0xFFFFFFFF, and a
        // platform channel is not a place to take a trap, so the mapping
        // truncates -- the same low-32-bit truncation Android's toInt() does.
        // 0x80 alpha proves the top byte survives: a packing that dropped it
        // would still look right for every opaque colour checked by hand.
        let native = PcAppearance(
            light: PcColors(brand: 0xFF1E_88E5, component: 0x80FF_FFFF),
            dark: PcColors(brand: 0xFF64_B5F6),
            themeMode: .dark,
            shapes: PcShapes(cornerRadius: 16, buttonCornerRadius: 28, borderWidth: 2),
            primaryButton: PcPrimaryButton(background: 0xFF1E_88E5, height: 56),
            typography: PcTypography(sizeScaleFactor: 1.1)
        ).toNative()

        XCTAssertEqual(native.light.brand, PayCrossColor(argb: 0xFF1E_88E5))
        XCTAssertEqual(native.light.component, PayCrossColor(argb: 0x80FF_FFFF))
        XCTAssertEqual(native.dark.brand, PayCrossColor(argb: 0xFF64_B5F6))
        XCTAssertEqual(native.themeMode, .dark)
        XCTAssertEqual(native.shapes.cornerRadius, 16)
        XCTAssertEqual(native.shapes.buttonCornerRadius, 28)
        XCTAssertEqual(native.shapes.borderWidth, 2)
        XCTAssertEqual(native.primaryButton.background, PayCrossColor(argb: 0xFF1E_88E5))
        XCTAssertEqual(native.primaryButton.height, 56)
        XCTAssertEqual(native.typography.sizeScaleFactor, 1.1)
    }

    func testAnEmptyAppearanceSubstitutesEmptyStructsRatherThanInventingValues() {
        // The SDK's sub-structs are non-optional, so a nil on the wire has to
        // become something. An empty struct is the right something: every role
        // in it is nil, which is what the sheet reads as "keep the platform
        // default" -- the same thing the nil meant. A default-constructed
        // struct carrying real values would silently theme a sheet nobody
        // asked to theme.
        let native = PcAppearance(themeMode: .system).toNative()

        XCTAssertNil(native.light.brand)
        XCTAssertNil(native.light.surface)
        XCTAssertNil(native.dark.brand)
        XCTAssertNil(native.shapes.cornerRadius)
        XCTAssertNil(native.shapes.borderWidth)
        XCTAssertNil(native.primaryButton.background)
        XCTAssertNil(native.primaryButton.height)
        XCTAssertNil(native.typography.sizeScaleFactor)
        XCTAssertEqual(native.themeMode, .system)
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
