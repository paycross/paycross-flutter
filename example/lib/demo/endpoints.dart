/// The PayCross endpoints this demo talks to, in both environments, and the
/// only ones it can reach.
///
/// Constants, not settings. The environment toggle picks one of the two
/// [Endpoints] values below; there is still no user-editable URL anywhere
/// in this app, and there is still no third environment.
///
/// What the toggle costs is the guarantee this file used to make -- that a
/// build on somebody's phone could not reach production at all. That
/// guarantee is now `environment.dart`'s: production is reachable, behind a
/// typed word, with credentials that live in RAM and die with the process.
library;

/// The M2M client-credentials endpoint.
///
/// The `scope` is part of the URL and is **required**: without it the token
/// endpoint answers 400. Same host as the merchant API, not a separate `auth.`
/// one -- `auth.test-pay-cross.com` resolves but 404s every path, so a DNS
/// check would not have caught the difference.
const String tokenUrl =
    'https://api.test-pay-cross.com/oauth2/token?scope=paycross/payments';

/// Production's M2M endpoint. Carries the same required `scope` query the
/// TEST one does -- the endpoint answers 400 without it, on both.
const String liveTokenUrl =
    'https://api.pay-cross.com/oauth2/token?scope=paycross/payments';

/// The merchant API's create-session collection.
///
/// Hyphenated on purpose: the merchant API routes `/payment-sessions` only,
/// which is why the Android demo's minter rewrites the underscored spelling
/// (`SessionMinter.sessionsUrl`). This app pins the routed form instead of
/// rewriting one it was handed.
const String sessionsUrl = 'https://api.test-pay-cross.com/payment-sessions';

/// Production's create-session collection, in the hyphenated spelling the
/// merchant API routes.
const String liveSessionsUrl = 'https://api.pay-cross.com/payment-sessions';

/// One environment's two URLs, so a caller passes a pair rather than two
/// strings it could mix.
///
/// The failure this shape rules out is minting a session on one environment
/// with a token issued by the other: the API answers 401 and it reads as a
/// bad credential rather than as a mismatched pair.
class Endpoints {
  const Endpoints({required this.tokenUrl, required this.sessionsUrl});

  final String tokenUrl;
  final String sessionsUrl;
}

/// The sandbox. Every cold start, every automation run, and the default of
/// every seam in this app that takes an [Endpoints].
const Endpoints testEndpoints = Endpoints(
  tokenUrl: tokenUrl,
  sessionsUrl: sessionsUrl,
);

/// Production. Read from the native Android demo's `EditorScreens.kt`
/// (`PROD_TOKEN_URL`, `PROD_PAYMENT_API_URL`), which is the one place in
/// this organisation where these two strings are already written down and
/// exercised.
const Endpoints liveEndpoints = Endpoints(
  tokenUrl: liveTokenUrl,
  sessionsUrl: liveSessionsUrl,
);

/// The API version these request bodies are written against.
const String paycrossVersion = '2026-06-16';

/// Cloudflare in front of the TEST API refuses a default client User-Agent
/// outright. Every seed script and the matrix runner send a browser UA; so
/// does this. It is necessary but not sufficient -- Cloudflare fingerprints
/// the TLS handshake too -- so the minter reports an HTML refusal as its own
/// error rather than as a JSON parse failure.
const String userAgent =
    'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/140.0 Safari/537.36';
