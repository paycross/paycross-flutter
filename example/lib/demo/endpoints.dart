/// The PayCross **sandbox** endpoints this demo talks to, and the only ones
/// it can reach.
///
/// Constants, not settings. A build of this app holds TEST M2M credentials
/// on somebody's phone; a switch that pointed them at production would be
/// the one bug in it that mattered. Settings says so on screen.
library;

/// The M2M client-credentials endpoint.
///
/// The `scope` is part of the URL and is **required**: without it the token
/// endpoint answers 400. Same host as the merchant API, not a separate `auth.`
/// one -- `auth.test-pay-cross.com` resolves but 404s every path, so a DNS
/// check would not have caught the difference.
const String tokenUrl =
    'https://api.test-pay-cross.com/oauth2/token?scope=paycross/payments';

/// The merchant API's create-session collection.
///
/// Hyphenated on purpose: the merchant API routes `/payment-sessions` only,
/// which is why the Android demo's minter rewrites the underscored spelling
/// (`SessionMinter.sessionsUrl`). This app pins the routed form instead of
/// rewriting one it was handed.
const String sessionsUrl = 'https://api.test-pay-cross.com/payment-sessions';

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
