package com.paycross.flutter

import com.paycross.flutter.generated.FlutterError
import com.paycross.flutter.generated.PcAppearance
import com.paycross.flutter.generated.PcCancelled
import com.paycross.flutter.generated.PcColors
import com.paycross.flutter.generated.PcFailure
import com.paycross.flutter.generated.PcPaymentResult
import com.paycross.flutter.generated.PcPending
import com.paycross.flutter.generated.PcPrimaryButton
import com.paycross.flutter.generated.PcShapes
import com.paycross.flutter.generated.PcSuccess
import com.paycross.flutter.generated.PcThemeMode
import com.paycross.flutter.generated.PcTypography
import com.paycross.sdk.PayCrossResult
import com.paycross.sdk.PendingReason
import com.paycross.sdk.Recovery
import com.paycross.sdk.ThemeMode
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

        assertEquals("0.6.0", info.pluginVersion)
        // The Android SDK declares no version constant; the plugin reports
        // null rather than fabricating one.
        assertNull(info.nativeSdkVersion)
    }

    @Test
    fun success_carriesTheTokenOfACardThisPaymentSaved() {
        val pigeon = PayCrossResult.Success(
            transactionId = "tx-5",
            status = "success",
            amount = 1250L,
            currency = "EUR",
            savedCardToken = "tok"
        ).toPigeon() as PcSuccess

        // The merchant's only route to the vault reference: the sheet that
        // saved the card is the SDK's own, so nothing else crosses it.
        assertEquals("tok", pigeon.savedCardToken)
    }

    @Test
    fun success_withoutASavedCard_carriesNoToken() {
        val pigeon = PayCrossResult.Success(
            transactionId = "tx-6",
            status = "success",
            amount = 1250L,
            currency = "EUR"
        ).toPigeon() as PcSuccess

        // Saving is asked for at session creation, so most payments save
        // nothing and this must stay null rather than becoming "".
        assertNull(pigeon.savedCardToken)
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
    fun appearance_everyFieldReachesTheSdk() {
        val pigeon = PcAppearance(
            light = PcColors(
                brand = 0xFF1E88E5L,
                onBrand = 0xFFFFFFFFL,
                surface = 0xFFF7F7F7L,
                component = 0x80FFFFFFL,
                componentBorder = 0xFFD0D0D0L,
                text = 0xFF111111L,
                textSecondary = 0xFF666666L,
                placeholder = 0xFF999999L,
                icon = 0xFF444444L,
                error = 0xFFB3261EL
            ),
            dark = PcColors(brand = 0xFF64B5F6L),
            themeMode = PcThemeMode.DARK,
            shapes = PcShapes(cornerRadius = 16.0, buttonCornerRadius = 28.0, borderWidth = 2.0),
            primaryButton = PcPrimaryButton(
                background = 0xFF1E88E5L,
                textColor = 0xFFFFFFFFL,
                disabledBackground = 0x611E88E5L,
                disabledTextColor = 0x61FFFFFFL,
                cornerRadius = 24.0,
                height = 56.0
            ),
            typography = PcTypography(sizeScaleFactor = 1.1)
        )

        val native = pigeon.toNative()

        val light = requireNotNull(native.light)
        // Every role, because a field that silently stops crossing is
        // invisible until a merchant's sheet is the wrong colour. The 0x80
        // alpha proves the top byte survives: a packing that dropped it would
        // still look right for every opaque colour anybody checks by hand.
        assertEquals(0xFF1E88E5.toInt(), light.brand)
        assertEquals(0xFFFFFFFF.toInt(), light.onBrand)
        assertEquals(0xFFF7F7F7.toInt(), light.surface)
        assertEquals(0x80FFFFFF.toInt(), light.component)
        assertEquals(0xFFD0D0D0.toInt(), light.componentBorder)
        assertEquals(0xFF111111.toInt(), light.text)
        assertEquals(0xFF666666.toInt(), light.textSecondary)
        assertEquals(0xFF999999.toInt(), light.placeholder)
        assertEquals(0xFF444444.toInt(), light.icon)
        assertEquals(0xFFB3261E.toInt(), light.error)

        assertEquals(0xFF64B5F6.toInt(), native.dark?.brand)
        assertEquals(ThemeMode.DARK, native.themeMode)

        assertEquals(16f, native.shapes?.cornerRadius)
        assertEquals(28f, native.shapes?.buttonCornerRadius)
        assertEquals(2f, native.shapes?.borderWidth)

        assertEquals(0xFF1E88E5.toInt(), native.primaryButton?.background)
        assertEquals(0xFFFFFFFF.toInt(), native.primaryButton?.textColor)
        assertEquals(0x611E88E5.toInt(), native.primaryButton?.disabledBackground)
        assertEquals(0x61FFFFFF.toInt(), native.primaryButton?.disabledTextColor)
        assertEquals(24f, native.primaryButton?.cornerRadius)
        assertEquals(56f, native.primaryButton?.height)

        assertEquals(1.1f, native.typography?.sizeScaleFactor)
    }

    @Test
    fun appearance_nullsArePreservedRatherThanZeroed() {
        val native = PcAppearance(
            light = PcColors(brand = 0xFF6750A4L),
            themeMode = PcThemeMode.SYSTEM
        ).toNative()

        // Zero is not absence here: 0x00000000 is transparent black, a legal
        // colour the SDK would paint. Absence has to stay null all the way
        // down, because that is what the SDK reads as "keep the platform
        // default".
        assertEquals(0xFF6750A4.toInt(), native.light?.brand)
        assertNull(native.light?.surface)
        assertNull(native.light?.onBrand)
        assertNull(native.dark)
        assertNull(native.shapes)
        assertNull(native.primaryButton)
        assertNull(native.typography)
        assertEquals(ThemeMode.SYSTEM, native.themeMode)
    }

    @Test
    fun appearance_everyThemeModeMapsToItsOwnCase() {
        val expected = mapOf(
            PcThemeMode.SYSTEM to ThemeMode.SYSTEM,
            PcThemeMode.LIGHT to ThemeMode.LIGHT,
            PcThemeMode.DARK to ThemeMode.DARK
        )

        for (mode in PcThemeMode.entries) {
            assertEquals(expected[mode], PcAppearance(themeMode = mode).toNative().themeMode)
        }
        // A mode added to the wire fails on the map above rather than being
        // quietly folded into SYSTEM.
        assertEquals(expected.keys, PcThemeMode.entries.toSet())
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
