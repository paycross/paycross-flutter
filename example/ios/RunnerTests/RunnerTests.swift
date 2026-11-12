import Flutter
import PayCross
import PayCrossCore
import UIKit
import XCTest

@testable import paycross_flutter

class RunnerTests: XCTestCase {

    func testEveryRecoveryHasANonEmptyWireToken() {
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
