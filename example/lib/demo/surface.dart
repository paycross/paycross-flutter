/// Where a minted session is presented to the person paying.
///
/// Two surfaces over one mint. Every tile builds the same body and sends it
/// through the same minter whichever of these is chosen -- the choice lands
/// after the session exists, on what happens to it next, which is what makes
/// the two comparable at all.
///
/// It is chosen per run, on the tile, and it is not remembered. There is no
/// stored preference and no screen that sets one: a tester comparing a
/// wallet in the browser against the sheet on the same merchant is switching
/// back and forth, and a mode they have to go and set is a mode they will
/// forget they are in. What runs is what they pressed.
enum PaymentSurface {
  /// The native SDK sheet, in the app. What tapping a tile does.
  sdkSheet,

  /// The hosted checkout page, in the phone's own browser. What the tile's
  /// "Open in browser" button does.
  ///
  /// It exists because the production checkout page is already approved for
  /// Google Pay and Apple Pay: a tester can exercise both wallets from the
  /// same demo session and the same identity today, and hold the result up
  /// against what the sheet does on the same merchant.
  webCheckout,
}

/// What a surface is called in a History row.
///
/// Short strings rather than the enum's own `name`, and pinned by a test: a
/// row written today is read by a build shipped months later, so these two
/// words are a stored format rather than an implementation detail. They are
/// also deliberately not the deep link's vocabulary -- `deeplink.dart` spells
/// its one surface `sheet` -- because a link's grammar and a stored row are
/// two things that happen to be about the same idea, and tying them together
/// would mean a link could never be renamed without rewriting history.
String surfaceName(PaymentSurface surface) => switch (surface) {
  PaymentSurface.sdkSheet => sdkSurfaceName,
  PaymentSurface.webCheckout => webSurfaceName,
};

/// The stored word for [PaymentSurface.sdkSheet].
const String sdkSurfaceName = 'sdk';

/// The stored word for [PaymentSurface.webCheckout].
const String webSurfaceName = 'web';

/// What every tile's browser button says.
///
/// Named once and read by all thirteen tiles, so the eight presets, Custom
/// and the three Live tiles cannot end up calling the same action three
/// different things -- and so a test asserts against the app's own word for
/// it rather than a copy of it.
const String openInBrowserLabel = 'Open in browser';

/// The longer sentence the button carries as a tooltip.
///
/// The tile has no room for it and the label alone does not say what is
/// about to be minted, which on a Live tile is the whole question.
const String openInBrowserHint =
    'Mint this scenario and open the hosted checkout page in your browser';

/// The key one tile's browser button carries.
///
/// Built from the tile's own name rather than its position, so reordering
/// the preset list does not move a key and a test that names a tile cannot
/// quietly start asserting about a different one.
String browserActionKey(String tile) => 'openInBrowser:$tile';
