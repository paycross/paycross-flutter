package com.paycross.flutter

import com.paycross.flutter.generated.FlutterError
import com.paycross.flutter.generated.PcPaymentResult
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

        assertEquals("0.2.0", info.pluginVersion)
        // The Android SDK declares no version constant; the plugin reports
        // null rather than fabricating one.
        assertNull(info.nativeSdkVersion)
    }
}
