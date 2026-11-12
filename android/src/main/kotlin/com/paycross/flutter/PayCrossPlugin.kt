package com.paycross.flutter

import android.app.Activity
import android.content.Intent
import com.paycross.flutter.generated.PayCrossHostApi
import com.paycross.flutter.generated.FlutterError
import com.paycross.flutter.generated.PcAmount
import com.paycross.flutter.generated.PcAppearance
import com.paycross.flutter.generated.PcCancelled
import com.paycross.flutter.generated.PcColors
import com.paycross.flutter.generated.PcConfiguration
import com.paycross.flutter.generated.PcEnvironment
import com.paycross.flutter.generated.PcFailure
import com.paycross.flutter.generated.PcPaymentResult
import com.paycross.flutter.generated.PcPending
import com.paycross.flutter.generated.PcPrimaryButton
import com.paycross.flutter.generated.PcShapes
import com.paycross.flutter.generated.PcSuccess
import com.paycross.flutter.generated.PcTestCardPrefill
import com.paycross.flutter.generated.PcThemeMode
import com.paycross.flutter.generated.PcTypography
import com.paycross.flutter.generated.PcVersionInfo
import com.paycross.sdk.PayCross
import com.paycross.sdk.PayCrossAppearance
import com.paycross.sdk.PayCrossColors
import com.paycross.sdk.PayCrossContract
import com.paycross.sdk.PayCrossEnvironment
import com.paycross.sdk.PayCrossPrimaryButton
import com.paycross.sdk.PayCrossResult
import com.paycross.sdk.PayCrossShapes
import com.paycross.sdk.PayCrossTypography
import com.paycross.sdk.PendingReason
import com.paycross.sdk.Recovery
import com.paycross.sdk.TestCardPrefill
import com.paycross.sdk.ThemeMode
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.PluginRegistry

/** Flutter plugin that bridges the Dart API onto the native Android SDK. */
class PayCrossPlugin : FlutterPlugin, ActivityAware, PayCrossHostApi {

    private var binding: ActivityPluginBinding? = null

    private val resultListener = PluginRegistry.ActivityResultListener { requestCode, resultCode, data ->
        if (requestCode != REQUEST_CODE) return@ActivityResultListener false
        deliver(resultCode, data)
        true
    }

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        PayCrossHostApi.setUp(flutterPluginBinding.binaryMessenger, this)
    }

    override fun onDetachedFromEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        PayCrossHostApi.setUp(flutterPluginBinding.binaryMessenger, null)
        finishPending(
            Result.failure(
                integrationError(
                    ERROR_RESULT_UNKNOWN,
                    "The Flutter engine detached while a payment was in flight. " +
                        "The payment may still have succeeded; reconcile server-side."
                )
            )
        )
    }

    // MARK: - ActivityAware

    override fun onAttachedToActivity(b: ActivityPluginBinding) = attach(b)

    override fun onReattachedToActivityForConfigChanges(b: ActivityPluginBinding) = attach(b)

    override fun onDetachedFromActivityForConfigChanges() = detach()

    override fun onDetachedFromActivity() {
        detach()
        finishPending(
            Result.failure(
                integrationError(
                    ERROR_RESULT_UNKNOWN,
                    "The Activity was destroyed while a payment was in flight. " +
                        "The payment may still have succeeded; reconcile server-side."
                )
            )
        )
    }

    private fun attach(b: ActivityPluginBinding) {
        binding = b
        b.addActivityResultListener(resultListener)
    }

    private fun detach() {
        binding?.removeActivityResultListener(resultListener)
        binding = null
    }

    // MARK: - PayCrossHostApi

    override fun configure(configuration: PcConfiguration) {
        if (pending != null) {
            // Changing the environment resets the Retrofit client, which is undefined under a live poll loop.
            throw integrationError(ERROR_BUSY, "Cannot reconfigure while a payment is in flight.")
        }
        cached = configuration
        applyConfiguration(configuration)
    }

    override fun versionInfo(): PcVersionInfo = PcVersionInfo(
        pluginVersion = PLUGIN_VERSION,
        // The Android SDK declares no version constant, so this stays null.
        nativeSdkVersion = null
    )

    override fun presentPayment(sessionToken: String, callback: (Result<PcPaymentResult>) -> Unit) {
        if (sessionToken.isBlank()) {
            return callback(
                Result.failure(integrationError(ERROR_INVALID_TOKEN, "The session token is empty."))
            )
        }

        val configuration = cached
            ?: return callback(
                Result.failure(
                    integrationError(ERROR_NOT_CONFIGURED, "configure() must be called before presentPayment().")
                )
            )

        val activity = binding?.activity
            ?: return callback(
                Result.failure(
                    integrationError(ERROR_NO_ACTIVITY, "The plugin is not attached to an Activity.")
                )
            )

        // The latch is process-wide because Flutter engines share one Activity task.
        synchronized(LOCK) {
            if (pending != null) {
                return callback(
                    Result.failure(integrationError(ERROR_BUSY, "A payment is already in flight."))
                )
            }
            pending = callback
        }

        // Re-applied on every call, because a hot restart resets the SDK's process state.
        applyConfiguration(configuration)

        try {
            val intent = PayCrossContract().createIntent(activity, sessionToken)
            activity.startActivityForResult(intent, REQUEST_CODE)
        } catch (e: Exception) {
            finishPending(
                Result.failure(
                    integrationError(
                        ERROR_NO_ACTIVITY,
                        "Could not start the payment Activity: ${e.message}. " +
                            "A host Activity with launchMode singleInstance cannot receive results."
                    )
                )
            )
        }
    }

    // MARK: - Result plumbing

    private fun deliver(resultCode: Int, data: Intent?) {
        // parseResult reads a lost payload as Cancelled, so the payload is checked first.
        val lost = resultCode == Activity.RESULT_OK && data?.hasExtra(EXTRA_RESULT) != true
        if (lost) {
            // A lost result is a success, not an error: the payment may have been authorized.
            return finishPending(Result.success(lostResult()))
        }

        val result = try {
            PayCrossContract().parseResult(resultCode, data)
        } catch (e: Exception) {
            return finishPending(
                Result.failure(
                    integrationError(
                        ERROR_RESULT_UNKNOWN,
                        "Could not read the payment result: ${e.message}. Reconcile server-side."
                    )
                )
            )
        }

        finishPending(Result.success(result.toPigeon()))
    }

    private fun finishPending(result: Result<PcPaymentResult>) {
        val callback = synchronized(LOCK) {
            pending.also { pending = null }
        } ?: return
        callback(result)
    }

    private fun applyConfiguration(configuration: PcConfiguration) {
        PayCross.init(
            environment = configuration.environment.toNative(),
            // toInt() keeps the low 32 bits, which is the signed @ColorInt the SDK expects.
            brandColor = configuration.brandColorArgb?.toInt(),
            testCardPrefill = configuration.testCardPrefill?.toNative(),
            // Google rejects a production request without a merchant ID, so it is passed through as is.
            googlePayMerchantId = configuration.googlePayMerchantId,
            // Apple Pay is iOS only, so there is no Android wallet to configure with applePayMerchantId.
            appearance = configuration.appearance?.toNative(),
            // The SDK owns locale resolution and skips a malformed tag, so the value is not checked here.
            locale = configuration.locale
        )
    }

    private companion object {
        // Not 0, because the host Activity's own result codes share this space.
        const val REQUEST_CODE = 0x5043

        const val EXTRA_RESULT = "result"

        const val PLUGIN_VERSION = "0.8.0"

        const val ERROR_NOT_CONFIGURED = "paycross_not_configured"
        const val ERROR_BUSY = "paycross_busy"
        const val ERROR_NO_ACTIVITY = "paycross_no_activity"
        const val ERROR_INVALID_TOKEN = "paycross_invalid_token"
        const val ERROR_RESULT_UNKNOWN = "paycross_result_unknown"

        val LOCK = Any()

        var pending: ((Result<PcPaymentResult>) -> Unit)? = null
        var cached: PcConfiguration? = null

        // FlutterError is what Pigeon forwards to Dart with the code intact.
        fun integrationError(code: String, message: String) = FlutterError(code, message)
    }
}

// MARK: - Mapping

private fun PcEnvironment.toNative(): PayCrossEnvironment = when (this) {
    // The Android SDK names the non-production environment STAGING.
    PcEnvironment.SANDBOX -> PayCrossEnvironment.STAGING
    PcEnvironment.PRODUCTION -> PayCrossEnvironment.PRODUCTION
}

private fun PcTestCardPrefill.toNative() = TestCardPrefill(
    cardholderName = cardholderName,
    pan = pan,
    expireMonth = expireMonth,
    expireYear = expireYear,
    cvv = cvv,
    saveCard = saveCard
)

internal fun PcColors.toNative() = PayCrossColors(
    brand = brand?.toInt(),
    onBrand = onBrand?.toInt(),
    surface = surface?.toInt(),
    component = component?.toInt(),
    componentBorder = componentBorder?.toInt(),
    text = text?.toInt(),
    textSecondary = textSecondary?.toInt(),
    placeholder = placeholder?.toInt(),
    icon = icon?.toInt(),
    error = error?.toInt()
)

internal fun PcShapes.toNative() = PayCrossShapes(
    cornerRadius = cornerRadius?.toFloat(),
    buttonCornerRadius = buttonCornerRadius?.toFloat(),
    borderWidth = borderWidth?.toFloat()
)

internal fun PcPrimaryButton.toNative() = PayCrossPrimaryButton(
    background = background?.toInt(),
    textColor = textColor?.toInt(),
    disabledBackground = disabledBackground?.toInt(),
    disabledTextColor = disabledTextColor?.toInt(),
    cornerRadius = cornerRadius?.toFloat(),
    height = height?.toFloat()
)

internal fun PcTypography.toNative() = PayCrossTypography(
    // The SDK clamps the scale too, for callers that skip the Dart range check.
    sizeScaleFactor = sizeScaleFactor?.toFloat()
)

internal fun PcThemeMode.toNative(): ThemeMode = when (this) {
    PcThemeMode.SYSTEM -> ThemeMode.SYSTEM
    PcThemeMode.LIGHT -> ThemeMode.LIGHT
    PcThemeMode.DARK -> ThemeMode.DARK
}

internal fun PcAppearance.toNative() = PayCrossAppearance(
    light = light?.toNative(),
    dark = dark?.toNative(),
    themeMode = themeMode.toNative(),
    shapes = shapes?.toNative(),
    primaryButton = primaryButton?.toNative(),
    typography = typography?.toNative()
)

internal fun PayCrossResult.toPigeon(): PcPaymentResult = when (this) {
    is PayCrossResult.Success -> PcSuccess(
        transactionId = transactionId,
        status = status,
        amount = PcAmount(minorUnits = amount, currencyCode = currency),
        savedCardToken = savedCardToken
    )

    is PayCrossResult.Failure -> PcFailure(
        transactionId = transactionId,
        // The server's own recovery string passes through unchanged, so Dart can read values this SDK cannot.
        recovery = recoveryRaw ?: recovery.toApiValue()
    )

    // Pending is not a decline, because the payment may already be authorized.
    is PayCrossResult.Pending -> PcPending(
        transactionId = transactionId,
        // The enum's wire name keeps this in step with the iOS SDK.
        reason = reason.wireName
    )

    is PayCrossResult.Cancelled -> PcCancelled(transactionId = transactionId)
}

internal fun lostResult(): PcPending =
    PcPending(transactionId = null, reason = PendingReason.RESULT_LOST.wireName)

internal fun Recovery.toApiValue(): String = when (this) {
    Recovery.RETRY -> "retry"
    Recovery.CHANGE_METHOD -> "change_method"
    Recovery.RESTART -> "restart"
    Recovery.CONTACT_SUPPORT -> "contact_support"
    Recovery.DO_NOT_RETRY -> "do_not_retry"
    Recovery.VERIFY_BEFORE_RETRY -> "verify_before_retry"
    // Never the empty string, which Dart reads as absent and so retries.
    Recovery.UNRECOGNIZED -> "unrecognized"
}
