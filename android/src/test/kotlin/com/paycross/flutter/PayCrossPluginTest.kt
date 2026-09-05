package com.paycross.flutter

import com.paycross.flutter.generated.FlutterError
import com.paycross.flutter.generated.PcCancelled
import com.paycross.flutter.generated.PcFailure
import com.paycross.flutter.generated.PcPaymentResult
import com.paycross.flutter.generated.PcPending
import com.paycross.sdk.PayCrossResult
import com.paycross.sdk.PendingReason
import com.paycross.sdk.Recovery
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/*
 * JVM-only tests of the plugin's guard rails: the paths that fail before any
 * Activity is launched or any native SDK call is made. The happy path needs a
 * real Activity and the SDK's own payment screen, so it can only be exercised
 * on a device.
 *
 * None of these tests call configure(). The cached configuration is
 * process-wide (see the companion object in PayCrossPlugin), so configuring in
 * one test would leak into every other test in this JVM and break the
 * not-configured assertion.
 *
 * Run with `./gradlew testDebugUnitTest` in `example/android/`.
 */
internal class PayCrossPluginTest {

    private fun presentPaymentError(token: String): FlutterError {
        var result: Result<PcPaymentResult>? = null
        PayCrossPlugin().presentPayment(token) { result = it }
        val error = requireNotNull(result) { "the callback was never invoked" }
            .exceptionOrNull()
        return error as? FlutterError
            ?: throw AssertionError("expected a FlutterError, got $error")
    }

    @Test
    fun presentPayment_withBlankToken_failsWithInvalidToken() {
        assertEquals("paycross_invalid_token", presentPaymentError("  ").code)
    }

    @Test
    fun presentPayment_beforeConfigure_failsWithNotConfigured() {
        assertEquals("paycross_not_configured", presentPaymentError("token").code)
    }

    @Test
    fun versionInfo_reportsPluginVersionAndNoNativeVersion() {
        val info = PayCrossPlugin().versionInfo()

        assertEquals("0.3.0", info.pluginVersion)
        // The Android SDK declares no version constant; the plugin reports
        // null rather than fabricating one.
        assertNull(info.nativeSdkVersion)
    }

    @Test
    fun failure_sendsTheServersOwnRecoveryValue() {
        val pigeon = PayCrossResult.Failure(
            transactionId = "tx-1",
            recovery = Recovery.UNRECOGNIZED,
            recoveryRaw = "issuer_wants_a_phone_call"
        ).toPigeon() as PcFailure

        // Verbatim, so Dart lands on RecoveryUnrecognized with the real token
        // rather than reporting a terminal decline it never received.
        assertEquals("issuer_wants_a_phone_call", pigeon.recovery)
    }

    @Test
    fun failure_withoutAServerValue_sendsTheCanonicalToken() {
        val pigeon = PayCrossResult.Failure(
            transactionId = "tx-2",
            recovery = Recovery.VERIFY_BEFORE_RETRY
        ).toPigeon() as PcFailure

        assertEquals("verify_before_retry", pigeon.recovery)
    }

    @Test
    fun everyRecoveryHasATokenAndNoneOfThemIsEmpty() {
        // The empty string is how both SDKs spell "the server said nothing",
        // which Dart reads as retry. No enum member may collapse to it.
        for (recovery in Recovery.entries) {
            assertEquals(
                true,
                recovery.toApiValue().isNotEmpty(),
                "$recovery produced an empty wire token"
            )
        }
    }

    @Test
    fun cancellation_carriesTheAttemptItWalkedAwayFrom() {
        val pigeon = PayCrossResult.Cancelled(transactionId = "tx-3").toPigeon()

        assertEquals("tx-3", (pigeon as PcCancelled).transactionId)
    }

    @Test
    fun cancellation_beforeAnyTransaction_carriesNone() {
        val pigeon = PayCrossResult.Cancelled(transactionId = null).toPigeon()

        assertNull((pigeon as PcCancelled).transactionId)
    }

    @Test
    fun pending_crossesAsItsOwnCaseWithTheWireReason() {
        val pigeon = PayCrossResult.Pending(
            transactionId = "tx-4",
            reason = PendingReason.POLL_TIMEOUT
        ).toPigeon()

        // Its own case, not a Failure: this is the outcome where reading a
        // decline and offering a retry can charge the shopper twice.
        assertEquals("tx-4", (pigeon as PcPending).transactionId)
        assertEquals("poll_timeout", pigeon.reason)
    }

    @Test
    fun everyPendingReasonCrossesAsItsWireName() {
        // The vocabulary is agreed verbatim with the iOS SDK and with Dart's
        // parser. A member whose wire name drifts is a wire break, so it is
        // pinned here rather than only by the enum's own spelling.
        val expected = mapOf(
            PendingReason.POLL_TIMEOUT to "poll_timeout",
            PendingReason.RESULT_LOST to "result_lost",
            PendingReason.SERVER_VERIFY to "server_verify"
        )

        for (reason in PendingReason.entries) {
            val pigeon = PayCrossResult.Pending(
                transactionId = null,
                reason = reason
            ).toPigeon() as PcPending

            assertEquals(expected[reason], pigeon.reason, "$reason crossed as ${pigeon.reason}")
        }
        // A reason added to the SDK fails on the map above rather than
        // reaching Dart as an unpinned string.
        assertEquals(expected.keys, PendingReason.entries.toSet())
    }

    @Test
    fun aLostResultPayload_isPendingRatherThanAnError() {
        // The branch `deliver` takes when the Activity returns RESULT_OK with
        // no payload. It used to fail the call with `paycross_result_unknown`,
        // which reached merchants as a thrown exception rather than as the
        // unresolved payment it is.
        val pigeon = lostResult()

        assertEquals("result_lost", pigeon.reason)
        assertNull(pigeon.transactionId)
    }
}
