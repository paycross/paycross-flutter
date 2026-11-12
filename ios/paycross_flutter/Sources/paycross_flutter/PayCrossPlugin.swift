import Flutter
import Foundation
import PayCross
import PayCrossCore
import UIKit

/// Flutter plugin that bridges the Dart API onto the native iOS SDK.
public class PayCrossPlugin: NSObject, FlutterPlugin, PayCrossHostApi {
    public static func register(with registrar: FlutterPluginRegistrar) {
        PayCrossHostApiSetup.setUp(
            binaryMessenger: registrar.messenger(),
            api: PayCrossPlugin()
        )
    }

    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        PayCrossHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: nil)
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

        // WHY: the slot is process-wide and claimed atomically, because a check-then-set can present twice.
        // WHY: the completion is retained in the claim, so finishPending is the only way the call completes.
        guard Self.state.beginPresenting(completion) else {
            return completion(.failure(Self.error(Self.errorBusy, "A payment is already in flight.")))
        }

        Task { @MainActor in
            guard let presenter = Self.topmostViewController() else {
                return Self.finishPending(.failure(
                    Self.error(Self.errorNoPresenter, "No view controller is available to present from.")
                ))
            }

            // WHY: PaymentSheet.present traps in debug without a configuration, so it is re-applied on every call.
            Self.apply(configuration)

            let result = await PaymentSheet(sessionToken: sessionToken).present(from: presenter)
            Self.finishPending(.success(result.toPigeon()))
        }
    }

    private static func finishPending(_ result: Result<PcPaymentResult, Error>) {
        state.takePending()?(result)
    }

    // MARK: - Presentation

    // WHY: An add-to-app host may bury the Flutter view, so the sheet must come from the topmost controller.
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

    private static let state = PluginState()

    private static let pluginVersion = "0.7.4"

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
            applePayMerchantIdentifier: configuration.applePayMerchantId,
            appearance: configuration.appearance?.toNative()
                // WHY: Dart sends the deprecated brand colour only when no appearance is given.
                ?? configuration.brandColorArgb.map {
                    .brand(PayCrossColor(argb: UInt32(truncatingIfNeeded: $0)))
                },
            // WHY: The SDK resolves the locale itself and skips a malformed tag.
            locale: configuration.locale
        )
        // WHY: Google Pay's in-app API is Android and web only, so googlePayMerchantId has no iOS effect.
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

private extension Int64 {
    var asPayCrossColor: PayCrossColor {
        // WHY: Truncates like Android's toInt(); an exact UInt32(_:) traps outside 0...0xFFFFFFFF.
        PayCrossColor(argb: UInt32(truncatingIfNeeded: self))
    }
}

private extension PcColors {
    func toNative() -> PayCrossColors {
        PayCrossColors(
            brand: brand?.asPayCrossColor,
            onBrand: onBrand?.asPayCrossColor,
            surface: surface?.asPayCrossColor,
            component: component?.asPayCrossColor,
            componentBorder: componentBorder?.asPayCrossColor,
            text: text?.asPayCrossColor,
            textSecondary: textSecondary?.asPayCrossColor,
            placeholder: placeholder?.asPayCrossColor,
            icon: icon?.asPayCrossColor,
            error: error?.asPayCrossColor
        )
    }
}

private extension PcShapes {
    func toNative() -> PayCrossShapes {
        PayCrossShapes(
            cornerRadius: cornerRadius,
            buttonCornerRadius: buttonCornerRadius,
            borderWidth: borderWidth
        )
    }
}

private extension PcPrimaryButton {
    func toNative() -> PayCrossPrimaryButton {
        PayCrossPrimaryButton(
            background: background?.asPayCrossColor,
            textColor: textColor?.asPayCrossColor,
            disabledBackground: disabledBackground?.asPayCrossColor,
            disabledTextColor: disabledTextColor?.asPayCrossColor,
            cornerRadius: cornerRadius,
            height: height
        )
    }
}

private extension PcTypography {
    func toNative() -> PayCrossTypography {
        // WHY: The Dart facade already limits the scale to 0.8...1.3; the SDK clamps it too.
        PayCrossTypography(sizeScaleFactor: sizeScaleFactor)
    }
}

private extension PcThemeMode {
    func toNative() -> PayCrossThemeMode {
        switch self {
        case .system: return .system
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// WHY: Internal, not private: RunnerTests reaches this through @testable import.
extension PcAppearance {
    func toNative() -> PayCrossAppearance {
        // WHY: An empty SDK sub-struct draws the same as null, so the ?? defaults change nothing.
        PayCrossAppearance(
            light: light?.toNative() ?? PayCrossColors(),
            dark: dark?.toNative() ?? PayCrossColors(),
            themeMode: themeMode.toNative(),
            shapes: shapes?.toNative() ?? PayCrossShapes(),
            primaryButton: primaryButton?.toNative() ?? PayCrossPrimaryButton(),
            typography: typography?.toNative() ?? PayCrossTypography()
        )
    }
}

extension PaymentResult {
    func toPigeon() -> PcPaymentResult {
        switch self {
        case let .succeeded(transactionID, status, amount, savedCardToken):
            return PcSuccess(
                transactionId: transactionID,
                status: status,
                amount: PcAmount(
                    minorUnits: amount.minorUnits,
                    currencyCode: amount.currencyCode
                ),
                savedCardToken: savedCardToken
            )

        case let .failed(transactionID, recovery):
            return PcFailure(
                transactionId: transactionID,
                // WHY: The wire token, not the case name: .unrecognized keeps the server's own string.
                recovery: recovery.apiValue
            )

        case let .pending(transactionID, reason):
            // WHY: Pending has its own case; as a failure it would read as a decline in Dart.
            return PcPending(
                transactionId: transactionID,
                // WHY: The raw value is the wire vocabulary shared verbatim with the Android SDK.
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

// @unchecked Sendable: reads run on the channel thread, writes on the main actor; the lock keeps both safe.
private final class PluginState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedConfiguration: PcConfiguration?
    private var pending: ((Result<PcPaymentResult, Error>) -> Void)?

    var cached: PcConfiguration? {
        get { lock.withLock { storedConfiguration } }
        set { lock.withLock { storedConfiguration = newValue } }
    }

    var isPresenting: Bool { lock.withLock { pending != nil } }

    func beginPresenting(_ completion: @escaping (Result<PcPaymentResult, Error>) -> Void) -> Bool {
        lock.withLock {
            if pending != nil { return false }
            pending = completion
            return true
        }
    }

    func takePending() -> ((Result<PcPaymentResult, Error>) -> Void)? {
        lock.withLock {
            defer { pending = nil }
            return pending
        }
    }
}
