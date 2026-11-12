library;

/// The scope is part of the URL and is required: without it the token endpoint answers 400.
const String tokenUrl =
    'https://api.test-pay-cross.com/oauth2/token?scope=paycross/payments';

const String liveTokenUrl =
    'https://api.pay-cross.com/oauth2/token?scope=paycross/payments';

/// Hyphenated: the merchant API routes /payment-sessions only. The underscored spelling 404s.
const String sessionsUrl = 'https://api.test-pay-cross.com/payment-sessions';

const String liveSessionsUrl = 'https://api.pay-cross.com/payment-sessions';

class Endpoints {
  const Endpoints({required this.tokenUrl, required this.sessionsUrl});

  final String tokenUrl;
  final String sessionsUrl;
}

const Endpoints testEndpoints = Endpoints(
  tokenUrl: tokenUrl,
  sessionsUrl: sessionsUrl,
);

const Endpoints liveEndpoints = Endpoints(
  tokenUrl: liveTokenUrl,
  sessionsUrl: liveSessionsUrl,
);

const String paycrossVersion = '2026-06-16';

/// The TEST API refuses the default Dart User-Agent; send your own.
const String userAgent =
    'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/140.0 Safari/537.36';
