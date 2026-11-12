enum PaymentSurface { sdkSheet, webCheckout }

String surfaceName(PaymentSurface surface) => switch (surface) {
  PaymentSurface.sdkSheet => sdkSurfaceName,
  PaymentSurface.webCheckout => webSurfaceName,
};

const String sdkSurfaceName = 'sdk';

const String webSurfaceName = 'web';

const String openInBrowserLabel = 'Open in browser';

const String openInBrowserHint =
    'Mint this scenario and open the hosted checkout page in your browser';

String browserActionKey(String tile) => 'openInBrowser:$tile';
