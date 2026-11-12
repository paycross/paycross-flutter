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

        assertEquals("0.7.5", info.pluginVersion)
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

        assertNull(pigeon.savedCardToken)
    }

    @Test
    fun failure_sendsTheServersOwnRecoveryValue() {
        val pigeon = PayCrossResult.Failure(
            transactionId = "tx-1",
            recovery = Recovery.UNRECOGNIZED,
            recoveryRaw = "issuer_wants_a_phone_call"
        ).toPigeon() as PcFailure

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

        assertEquals("tx-4", (pigeon as PcPending).transactionId)
        assertEquals("poll_timeout", pigeon.reason)
    }

    @Test
    fun everyPendingReasonCrossesAsItsWireName() {
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
        assertEquals(expected.keys, PcThemeMode.entries.toSet())
    }

    @Test
    fun aLostResultPayload_isPendingRatherThanAnError() {
        val pigeon = lostResult()

        assertEquals("result_lost", pigeon.reason)
        assertNull(pigeon.transactionId)
    }
}
