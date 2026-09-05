import Flutter
import Foundation
import PayCross
import PayCrossCore
import UIKit

/// Bridges the Flutter surface onto the native iOS SDK.
///
/// The native SDK owns its own sheet, card form and 3DS web views. This class
/// presents it, waits, and translates one result back. It holds no payment
/// logic: anything it reimplemented would be a second, divergent copy of
/// behaviour the SDK is already tested for.
public class PayCrossPlugin: NSObject, FlutterPlugin, PayCrossHostApi {

    public static func register(with registrar: FlutterPluginRegistrar) {
        PayCrossHostApiSetup.setUp(
            binaryMessenger: registrar.messenger(),
            api: PayCrossPlugin()
        )
    }

    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        PayCrossHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: nil)
        // A payment sheet may still be on screen. Nothing can route its result
        // anywhere now, so say so rather than leaving the caller waiting on a
        // Future that can never complete. Mirrors Android's onDetachedFromEngine.
        Self.finishPending(.failure(Self.error(
            Self.errorResultUnknown,
            "The Flutter engine detached while a payment was in flight. "
                + "The payment may still have succeeded; reconcile server-side."
        )))
    }

    // MARK: - PayCrossHostApi

    func configure(configuration: PcConfiguration) throws {
        if Self.state.isPresenting {
            throw PigeonError(
                code: Self.errorBusy,
                message: "Cannot reconfigure while a payment is in flight.",
                details: nil
            )
        }
        Self.state.cached = configuration
        Self.apply(configuration)
    }

    func versionInfo() throws -> PcVersionInfo {
        PcVersionInfo(
            pluginVersion: Self.pluginVersion,
            nativeSdkVersion: PayCrossAPI.version
        )
    }

    func presentPayment(
        sessionToken: String,
        completion: @escaping (Result<PcPaymentResult, Error>) -> Void
    ) {
        guard !sessionToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return completion(.failure(Self.error(Self.errorInvalidToken, "The session token is empty.")))
        }

        guard let configuration = Self.state.cached else {
            return completion(.failure(
                Self.error(Self.errorNotConfigured, "configure() must be called before presentPayment().")
            ))
        }

        // Process-wide, matching Android. Two engines in an add-to-app host get
        // two plugin instances but share one window, so an instance-scoped flag
        // would let the second stack a sheet on the first.
        //
        // Claimed atomically rather than checked-then-set: the check ran on the
        // channel thread while the set ran on the main actor, so two calls in
        // quick succession could both pass a plain guard and present twice.
        //
        // The completion is retained in the claim so detachFromEngine can still
        // complete it. From here on the payment finishes only through
        // finishPending, which is what makes exactly-once hold between the
        // sheet's own result and an engine detach racing it.
        guard Self.state.beginPresenting(completion) else {
            return completion(.failure(Self.error(Self.errorBusy, "A payment is already in flight.")))
        }

        Task { @MainActor in
            guard let presenter = Self.topmostViewController() else {
                return Self.finishPending(.failure(
                    Self.error(Self.errorNoPresenter, "No view controller is available to present from.")
                ))
            }

            // Re-applied rather than assumed: a hot restart leaves the Dart side
            // believing it configured an SDK whose process state was reset, and
            // PaymentSheet.present traps on a missing configuration in debug.
            Self.apply(configuration)

            let result = await PaymentSheet(sessionToken: sessionToken).present(from: presenter)
            Self.finishPending(.success(result.toPigeon()))
        }
    }

    /// Completes the outstanding call exactly once, clearing the slot first.
    private static func finishPending(_ result: Result<PcPaymentResult, Error>) {
        state.takePending()?(result)
    }

    // MARK: - Presentation

    /// Walks to the view controller actually on screen.
    ///
    /// Flutter has no UIViewController of its own to hand out, and the merchant's
    /// hierarchy is not ours to assume: an add-to-app host may have the Flutter
    /// view buried, and a sheet presented from the wrong controller either does
    /// not appear or appears behind what the shopper is looking at.
    @MainActor
    private static func topmostViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first

        guard let root = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
            ?? scene?.windows.first?.rootViewController
        else { return nil }

        var top = root
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    // MARK: - State

    // Static, for the same reason Android's is: per-instance state is wrong when
    // instances are per-engine and the window is not. Behind a lock because the
    // reads happen on the platform-channel thread and the writes on the main
    // actor -- which is precisely what Swift 6 refuses to let us assume away.
    private static let state = PluginState()

    private static let pluginVersion = "0.3.0"

    private static let errorNotConfigured = "paycross_not_configured"
    private static let errorBusy = "paycross_busy"
    private static let errorNoPresenter = "paycross_no_presenter"
    private static let errorInvalidToken = "paycross_invalid_token"
    private static let errorResultUnknown = "paycross_result_unknown"

    private static func error(_ code: String, _ message: String) -> PigeonError {
        PigeonError(code: code, message: message, details: nil)
    }

    private static func apply(_ configuration: PcConfiguration) {
        PayCrossAPI.configure(
            environment: configuration.environment.toNative(),
            testCardPrefill: configuration.testCardPrefill?.toNative(),
            applePayMerchantIdentifier: configuration.applePayMerchantId
        )
        // brandColorArgb is deliberately ignored. The iOS SDK has no brand-colour
        // hook; its only colour source is the window tint, and setting that here
        // would inherit down the hierarchy and repaint the merchant's whole app.
        //
        // googlePayMerchantId is deliberately ignored: Google Pay's in-app API is
        // Android and web only, so there is no iOS wallet for it to configure.
    }
}

// MARK: - Mapping

private extension PcEnvironment {
    func toNative() -> PayCrossEnvironment {
        switch self {
        case .sandbox: return .sandbox
        case .production: return .production
        }
    }
}

private extension PcTestCardPrefill {
    func toNative() -> TestCardPrefill {
        TestCardPrefill(
            cardholderName: cardholderName,
            pan: pan,
            expireMonth: expireMonth,
            expireYear: expireYear,
            cvv: cvv,
            saveCard: saveCard
        )
    }
}

extension PaymentResult {
    func toPigeon() -> PcPaymentResult {
        switch self {
        case let .succeeded(transactionID, status, amount):
            return PcSuccess(
                transactionId: transactionID,
                status: status,
                amount: PcAmount(
                    minorUnits: amount.minorUnits,
                    currencyCode: amount.currencyCode
                )
            )

        case let .failed(transactionID, recovery):
            return PcFailure(
                transactionId: transactionID,
                // The wire token, not the case name. Dart re-parses it with the
                // same rules, and `.unrecognized` round-trips the server's own
                // string rather than collapsing to a known case.
                recovery: recovery.apiValue
            )

        case let .pending(transactionID, reason):
            // Its own case, not a `.failed` with a verify-before-retry
            // recovery. That reading is what made the one outcome that can
            // charge a shopper twice arrive in Dart looking like a decline.
            return PcPending(
                transactionId: transactionID,
                // The enum's raw value is the wire vocabulary itself, agreed
                // verbatim with the Android SDK, so there is no second
                // spelling here to drift from it.
                reason: reason.rawValue
            )

        case let .cancelled(transactionID):
            return PcCancelled(transactionId: transactionID)
        }
    }
}

extension Recovery {
    var apiValue: String {
        switch self {
        case .retry: return "retry"
        case .changeMethod: return "change_method"
        case .restart: return "restart"
        case .contactSupport: return "contact_support"
        case .doNotRetry: return "do_not_retry"
        case .verifyBeforeRetry: return "verify_before_retry"
        case let .unrecognized(value): return value
        }
    }
}

// MARK: - Shared state

/// Process-wide plugin state, serialised by a lock.
///
/// `@unchecked Sendable` is the honest annotation here: safety comes from the
/// lock, which the compiler cannot verify, rather than from the type system.
private final class PluginState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedConfiguration: PcConfiguration?
    private var pending: ((Result<PcPaymentResult, Error>) -> Void)?

    var cached: PcConfiguration? {
        get { lock.withLock { storedConfiguration } }
        set { lock.withLock { storedConfiguration = newValue } }
    }

    var isPresenting: Bool { lock.withLock { pending != nil } }

    /// Claims the presentation slot and retains the caller's completion,
    /// returning false if the slot was already taken. Test and set are one
    /// critical section so two callers cannot both win.
    func beginPresenting(_ completion: @escaping (Result<PcPaymentResult, Error>) -> Void) -> Bool {
        lock.withLock {
            if pending != nil { return false }
            pending = completion
            return true
        }
    }

    /// Releases the slot and hands back the retained completion, or nil if
    /// something else already finished this payment.
    func takePending() -> ((Result<PcPaymentResult, Error>) -> Void)? {
        lock.withLock {
            defer { pending = nil }
            return pending
        }
    }
}
