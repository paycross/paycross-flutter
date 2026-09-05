/// The wallet merchant identifiers this app is built with.
///
/// Three constants in one file rather than three values spread over the code
/// that uses them, because the mistake worth preventing is a Test identifier
/// reaching production. Side by side, that mistake is visible; threaded
/// through a configure call apiece, it is not.
///
/// None of these is a secret. An Apple Merchant ID is compiled into the app's
/// entitlement and a Google merchant id is sent to Google in every request;
/// both are public by construction, which is why they are constants here and
/// not entries in the secure store.
library;

/// The Apple Merchant ID registered for the TEST environment, with a
/// payment-processing certificate issued from the TEST back office.
///
/// Also the string in `ios/Runner/Runner.entitlements`, and the string saved
/// on the demo merchant in the TEST back office. All three must match: Apple
/// hashes it into every token's key, and the edge refuses a payment where the
/// SDK's copy and the merchant record's copy differ.
const String testApplePayMerchantId = 'merchant.pay-cross.com';

/// The Apple Merchant ID registered for production, with its own
/// payment-processing certificate issued from the PROD back office's
/// certificate request.
///
/// Its own identifier rather than the TEST one, decided by the owner on
/// 2026-09-02, because a Merchant ID carries at most two payment-processing
/// certificates and sharing one between environments spends both slots and
/// leaves no room to rotate either. The two environments' vaults hold
/// different keys, so a token minted under the wrong identifier decrypts
/// nowhere.
///
/// Listed in `ios/Runner/Runner.entitlements` beside the Test one, and saved
/// on the PROD demo merchant in the production back office.
const String liveApplePayMerchantId = 'merchant.pay-cross.com.prod';

/// The Google Pay merchant id from the Google Pay & Wallet Console, for
/// production.
///
/// Still the owner's to supply: it comes with production access for this app
/// in that console, which is a request Google grants rather than a value
/// anybody here can write down. Google rejects a production request whose
/// `merchantInfo` lacks one, so until it is filled in the Android SDK is
/// given null and renders no button -- which is the honest behaviour for an
/// account that has not been granted production access.
///
/// The Test id is not a constant at all -- a colleague types it into Settings
/// or passes it as a define -- because sandbox works without one.
///
/// The Google Pay & Wallet Console profile that owns the cleared hosted
/// checkout domain; Google requires it on production requests.
const String liveGooglePayMerchantId = 'BCR2DN5T52B53JQD';

/// An identifier, or null where there is not one yet.
///
/// Null is what both SDKs read as "render no button", which is the right
/// behaviour for an identifier nobody has registered. The same
/// empty-means-unset shape as `secrets.dart:114`, `main.dart:43` and
/// `settings.dart:177`.
String? walletIdOrNull(String value) => value.isEmpty ? null : value;
