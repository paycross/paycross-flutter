import Flutter
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

    // MARK: - PayCrossHostApi

    func configure(configuration: PcConfiguration) throws {
        if Self.isPresenting {
            throw PigeonError(
                code: Self.errorBusy,
                message: "Cannot reconfigure while a payment is in flight.",
                details: nil
            )
        }
        Self.cached = configuration
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

        guard let configuration = Self.cached else {
            return completion(.failure(
                Self.error(Self.errorNotConfigured, "configure() must be called before presentPayment().")
            ))
        }

        // Process-wide, matching Android. Two engines in an add-to-app host get
        // two plugin instances but share one window, so an instance-scoped flag
        // would let the second stack a sheet on the first.
        guard !Self.isPresenting else {
            return completion(.failure(Self.error(Self.errorBusy, "A payment is already in flight.")))
        }

        Task { @MainActor in
            guard let presenter = Self.topmostViewController() else {
                return completion(.failure(
                    Self.error(Self.errorNoPresenter, "No view controller is available to present from.")
                ))
            }

            Self.isPresenting = true
            // Re-applied rather than assumed: a hot restart leaves the Dart side
            // believing it configured an SDK whose process state was reset, and
            // PaymentSheet.present traps on a missing configuration in debug.
            Self.apply(configuration)

            let result = await PaymentSheet(sessionToken: sessionToken).present(from: presenter)
            Self.isPresenting = false
            completion(.success(result.toPigeon()))
        }
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
    // instances are per-engine and the window is not.
    private static var cached: PcConfiguration?
    private static var isPresenting = false

    private static let pluginVersion = "0.1.0"

    private static let errorNotConfigured = "paycross_not_configured"
    private static let errorBusy = "paycross_busy"
    private static let errorNoPresenter = "paycross_no_presenter"
    private static let errorInvalidToken = "paycross_invalid_token"

    private static func error(_ code: String, _ message: String) -> PigeonError {
        PigeonError(code: code, message: message, details: nil)
    }

    private static func apply(_ configuration: PcConfiguration) {
        PayCrossAPI.configure(
            environment: configuration.environment.toNative(),
            testCardPrefill: configuration.testCardPrefill?.toNative()
        )
        // brandColorArgb is deliberately ignored. The iOS SDK has no brand-colour
        // hook; its only colour source is the window tint, and setting that here
        // would inherit down the hierarchy and repaint the merchant's whole app.
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

private extension PaymentResult {
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

        case .cancelled:
            return PcCancelled()
        }
    }
}

private extension Recovery {
    var apiValue: String {
        switch self {
        case .retry: return "retry"
        case .changeMethod: return "change_method"
        case .restart: return "restart"
        case .contactSupport: return "contact_support"
        case .doNotRetry: return "do_not_retry"
        case let .unrecognized(value): return value
        }
    }
}
