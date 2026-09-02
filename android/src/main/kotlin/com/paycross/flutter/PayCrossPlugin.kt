package com.paycross.flutter

import android.app.Activity
import android.content.Intent
import com.paycross.flutter.generated.PayCrossHostApi
import com.paycross.flutter.generated.FlutterError
import com.paycross.flutter.generated.PcAmount
import com.paycross.flutter.generated.PcCancelled
import com.paycross.flutter.generated.PcConfiguration
import com.paycross.flutter.generated.PcEnvironment
import com.paycross.flutter.generated.PcFailure
import com.paycross.flutter.generated.PcPaymentResult
import com.paycross.flutter.generated.PcSuccess
import com.paycross.flutter.generated.PcTestCardPrefill
import com.paycross.flutter.generated.PcVersionInfo
import com.paycross.sdk.PayCross
import com.paycross.sdk.PayCrossContract
import com.paycross.sdk.PayCrossEnvironment
import com.paycross.sdk.PayCrossResult
import com.paycross.sdk.Recovery
import com.paycross.sdk.TestCardPrefill
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.PluginRegistry

/**
 * Bridges the Flutter surface onto the native Android SDK.
 *
 * The native SDK owns its own Activity, its card form and its 3DS WebViews. This
 * class starts it, waits, and translates one result back. It deliberately holds
 * no payment logic: anything it reimplemented would be a second, divergent copy
 * of behaviour the SDK is already tested for.
 */
class PayCrossPlugin : FlutterPlugin, ActivityAware, PayCrossHostApi {

    private var binding: ActivityPluginBinding? = null

    /**
     * Registered against whichever binding is current.
     *
     * A configuration change - rotation, or a dark-mode toggle, both plausible
     * over a payment that can run for eight minutes - tears the binding down and
     * hands back a new one. Holding the listener here lets it be re-registered
     * on reattach; without that the result arrives at a listener nobody is
     * subscribed to and the Dart Future hangs forever.
     */
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
        // A payment may still be on screen in the SDK's own Activity. Nothing can
        // route its result anywhere now, so say so rather than leaving the caller
        // waiting on a Future that can never complete.
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
        // Unlike a config change, this one is not followed by a reattach.
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
            // Changing the environment resets the Retrofit client, and resetting
            // it under a live poll loop is undefined.
            throw integrationError(ERROR_BUSY, "Cannot reconfigure while a payment is in flight.")
        }
        cached = configuration
        applyConfiguration(configuration)
    }

    override fun versionInfo(): PcVersionInfo = PcVersionInfo(
        pluginVersion = PLUGIN_VERSION,
        // The Android SDK declares no version constant. Null rather than a
        // fabricated string, so the gap stays visible.
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

        // Process-wide, not per-instance. Two Flutter engines in one process get
        // two plugin instances but share one Activity task, so an instance-scoped
        // latch would let the second engine stack a payment on the first.
        synchronized(LOCK) {
            if (pending != null) {
                return callback(
                    Result.failure(integrationError(ERROR_BUSY, "A payment is already in flight."))
                )
            }
            pending = callback
        }

        // Re-applied rather than assumed: a hot restart leaves the Dart side
        // believing it configured an SDK whose process-level state was reset.
        applyConfiguration(configuration)

        try {
            val intent = PayCrossContract().createIntent(activity, sessionToken)
            activity.startActivityForResult(intent, REQUEST_CODE)
        } catch (e: Exception) {
            // The Activity never launched, so no result will ever arrive.
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
        // parseResult collapses a lost result into Cancelled, so check for the
        // payload before trusting that reading. Without this a stripped
        // Parcelable - an over-eager R8 rule, a truncated Bundle - reports a
        // clean cancellation for a payment that may have been authorized.
        val lost = resultCode == Activity.RESULT_OK && data?.hasExtra(EXTRA_RESULT) != true
        if (lost) {
            return finishPending(
                Result.failure(
                    integrationError(
                        ERROR_RESULT_UNKNOWN,
                        "The payment Activity returned no result payload. The payment may " +
                            "still have succeeded; reconcile server-side."
                    )
                )
            )
        }

        val result = try {
            PayCrossContract().parseResult(resultCode, data)
        } catch (e: Exception) {
            // Parsing must not be able to strand the callback.
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

    /** Completes the outstanding call exactly once, clearing the latch first. */
    private fun finishPending(result: Result<PcPaymentResult>) {
        val callback = synchronized(LOCK) {
            pending.also { pending = null }
        } ?: return
        callback(result)
    }

    private fun applyConfiguration(configuration: PcConfiguration) {
        PayCross.init(
            environment = configuration.environment.toNative(),
            // toInt()'s low-32-bit truncation is exactly the signed @ColorInt
            // Android wants from an unsigned ARGB value.
            brandColor = configuration.brandColorArgb?.toInt(),
            testCardPrefill = configuration.testCardPrefill?.toNative(),
            // The SDK renders the Google Pay button itself; this is the only
            // thing it cannot infer. Google rejects a production request whose
            // merchantInfo lacks it, so it is passed straight through - null
            // being "not configured", which the SDK adds only when non-blank.
            googlePayMerchantId = configuration.googlePayMerchantId
            // applePayMerchantId is deliberately ignored: Apple Pay is iOS only,
            // so there is no Android wallet for it to configure. iOS forwards it
            // to the native SDK's applePayMerchantIdentifier.
        )
    }

    private companion object {
        // Distinctive rather than 0: the host Activity's own result codes share
        // this space.
        const val REQUEST_CODE = 0x5043

        /** Private to the SDK's internal PaymentActivity; mirrored deliberately. */
        const val EXTRA_RESULT = "result"

        const val PLUGIN_VERSION = "0.1.0"

        const val ERROR_NOT_CONFIGURED = "paycross_not_configured"
        const val ERROR_BUSY = "paycross_busy"
        const val ERROR_NO_ACTIVITY = "paycross_no_activity"
        const val ERROR_INVALID_TOKEN = "paycross_invalid_token"
        const val ERROR_RESULT_UNKNOWN = "paycross_result_unknown"

        val LOCK = Any()

        /**
         * Process-wide. See presentPayment: per-instance state is wrong here
         * because plugin instances are per-engine while the Activity task is not.
         */
        var pending: ((Result<PcPaymentResult>) -> Unit)? = null
        var cached: PcConfiguration? = null

        // Pigeon's own error type: it is what the generated code recognises and
        // forwards to Dart with the code intact. Anything else arrives as a
        // generic channel error with the code buried in a stack trace.
        fun integrationError(code: String, message: String) = FlutterError(code, message)
    }
}

// MARK: - Mapping

private fun PcEnvironment.toNative(): PayCrossEnvironment = when (this) {
    // The Android SDK calls the non-production environment STAGING.
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

private fun PayCrossResult.toPigeon(): PcPaymentResult = when (this) {
    is PayCrossResult.Success -> PcSuccess(
        transactionId = transactionId,
        status = status,
        amount = PcAmount(minorUnits = amount, currencyCode = currency)
    )

    is PayCrossResult.Failure -> PcFailure(
        transactionId = transactionId,
        // The canonical token, not the enum name. Dart re-parses it with the
        // same rules, so the two platforms agree without Dart having to know
        // Kotlin's naming.
        recovery = recovery.toApiValue()
    )

    PayCrossResult.Cancelled -> PcCancelled()
}

/**
 * Back to the wire token the server uses.
 *
 * Android's Recovery is a closed enum that discards the server's original
 * string, so an unrecognised value has already collapsed to DO_NOT_RETRY before
 * the plugin sees it. iOS preserves the raw value and will therefore produce
 * `unrecognized` where Android cannot. Documented asymmetry, fixable only in
 * the Android SDK.
 */
private fun Recovery.toApiValue(): String = when (this) {
    Recovery.RETRY -> "retry"
    Recovery.CHANGE_METHOD -> "change_method"
    Recovery.RESTART -> "restart"
    Recovery.CONTACT_SUPPORT -> "contact_support"
    Recovery.DO_NOT_RETRY -> "do_not_retry"
}
