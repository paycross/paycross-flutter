// ignore_for_file: prefer_initializing_formals
// The lint's own fix does not compile: Dart forbids a private NAMED
// parameter, so `this._x` cannot appear in a `{...}` list, and one of these
// fields holds a credential.
//
// File-level rather than one line-level ignore per field: the lint is
// reported on the initializer list, not on the parameters, and `dart format`
// pulls a comment written above the first initializer up onto the `}) :`
// line, where it applies to that line instead. Every initializer but the
// first can be suppressed narrowly; the first cannot, so the narrow form
// does not hold.

import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'endpoints.dart';
import 'secrets.dart';

/// How early to replace a bearer token, and the one constant here with a
/// hard upper bound rather than a preference.
///
/// A token minted at the origin at T0 expires at T0 + lifetime, but the
/// API-Gateway cache in front of the endpoint keeps serving it until
/// T0 + cacheTTL. A refresh fired at T0 + lifetime - margin only reaches the
/// origin while `margin < lifetime - cacheTTL`, which is 3600 - 3300 = 300 s
/// on TEST today. Get it wrong and the failure is not a stale token, it is a
/// busy loop: the gateway hands back the very same token, its `exp` has not
/// moved, and the client asks again immediately. Smaller is safe.
const Duration tokenRefreshMargin = Duration(seconds: 240);

const Duration _requestTimeout = Duration(seconds: 60);

const Set<String> _tokenKeys = {'session_token', 'saved_token', 'used_token'};

/// The merchant API did not do what was asked. Never carries a credential.
class MinterError implements Exception {
  const MinterError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One minted session. The token is a live credential with a short life: it
/// is handed to `presentPayment` once and then dropped.
class MintedSession {
  const MintedSession({
    required this.id,
    required this.token,
    required this.sentBody,
  });

  final String id;
  final String token;

  /// What was actually sent, placeholders substituted -- the editor shows
  /// it and the bug-report block quotes it.
  final String sentBody;
}

/// A v4 UUID from the platform's secure RNG.
///
/// Nine lines instead of a dependency, and injectable so the 401 test can
/// prove the replay reuses the key rather than minting a second session.
String randomUuidV4() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// The `exp` claim out of a JWT, or null if there is not one to read.
///
/// Deliberately does not verify the signature: this is scheduling, not
/// authentication. A forged `exp` costs one unnecessary refresh, and the API
/// is what decides whether a token is honoured. (Dart's `bool` is not an
/// `int`, so unlike the Python reference this needs no guard against
/// `exp: true`.)
DateTime? jwtExpiry(String token) {
  final parts = token.split('.');
  if (parts.length != 3) return null;
  try {
    final claims = jsonDecode(
      utf8.decode(base64.decode(base64.normalize(parts[1]))),
    );
    if (claims is! Map) return null;
    final exp = claims['exp'];
    if (exp is! num) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      (exp * 1000).round(),
      isUtc: true,
    );
  } catch (_) {
    return null;
  }
}

/// Drops the values a merchant-API resource carries that are credentials.
///
/// Every key ending `_url` is treated as carrying one, not `checkout_url`
/// alone: the same rule `evidence.py`'s `scrub_resource` applies, and one
/// field name is a worse thing to depend on than a suffix.
///
/// Keyed, never shaped. The API re-mints a `session_token` on every read of
/// an **open** session, so a shape rule anchored on a token this app already
/// holds would miss it -- and a partial match is worse than none, because it
/// leaves a headless remnant that reads as redacted and is not.
Object? scrubResource(Object? value) {
  if (value is Map) {
    return <String, Object?>{
      for (final entry in value.entries)
        '${entry.key}': _tokenKeys.contains(entry.key)
            ? '<redacted>'
            : '${entry.key}'.endsWith('_url')
            ? _withoutSessionParam(entry.value)
            : scrubResource(entry.value),
    };
  }
  if (value is List) return value.map(scrubResource).toList();
  return value;
}

Object? _withoutSessionParam(Object? value) {
  if (value is! String) return value;
  final uri = Uri.tryParse(value);
  if (uri == null || !uri.queryParameters.containsKey('session')) {
    return value;
  }
  return uri
      .replace(
        queryParameters: {...uri.queryParameters, 'session': '<redacted>'},
      )
      .toString();
}

/// A thin merchant-API client: one M2M token, mint, read.
///
/// This is the merchant-backend step of the flow, performed in-app for
/// testing only. A real integration does it server-side, never in the app.
class Minter {
  Minter({
    required Credentials credentials,
    http.Client? client,
    DateTime Function() now = DateTime.now,
    String Function() newIdempotencyKey = randomUuidV4,
    Duration timeout = _requestTimeout,
  }) : _credentials = credentials,
       _ownsClient = client == null,
       _client = client ?? http.Client(),
       _now = now,
       _newIdempotencyKey = newIdempotencyKey,
       _timeout = timeout;

  final Credentials _credentials;
  final http.Client _client;
  final bool _ownsClient;
  final DateTime Function() _now;
  final String Function() _newIdempotencyKey;
  final Duration _timeout;

  String? _accessToken;
  DateTime _accessTokenDeadline = DateTime.utc(1970);
  Future<String>? _bearerInFlight;

  /// Creates one session from a raw JSON body.
  ///
  /// `{{timestamp}}` and `{{uuid}}` are substituted first, the same two
  /// placeholders the Android demo's scenario bodies use.
  Future<MintedSession> mint(String body) async {
    final sent = substitutePlaceholders(body, now: _now);
    final Object? decoded;
    try {
      decoded = jsonDecode(sent);
    } on FormatException catch (error) {
      // Unguarded this escapes as a FormatException, and every failure out of
      // this module is supposed to be a MinterError the UI can render.
      throw MinterError('The session body is not JSON: ${error.message}');
    }
    if (decoded is! Map) {
      throw const MinterError('The session body must be a JSON object.');
    }

    final raw = await _send(
      'POST',
      Uri.parse(sessionsUrl),
      body: sent,
      extraHeaders: {
        'Content-Type': 'application/json',
        // Generated before the first attempt, so the 401 replay below sends
        // the same key rather than minting a second live session.
        'Idempotency-Key': _newIdempotencyKey(),
      },
    );

    final id = raw['id'];
    final token = raw['session_token'];
    if (id is! String || token is! String) {
      throw const MinterError('The mint returned no session_token.');
    }
    return MintedSession(id: id, token: token, sentBody: sent);
  }

  /// The merchant-side truth for one session, scrubbed before it is
  /// returned. Nothing above this method ever sees a live token.
  Future<Map<String, Object?>> read(String sessionId) async {
    final raw = await _send('GET', Uri.parse('$sessionsUrl/$sessionId'));
    return scrubResource(raw)! as Map<String, Object?>;
  }

  /// Releases the HTTP client, if this minter is the one that made it.
  ///
  /// A client that was passed in belongs to whoever passed it: closing it
  /// here would take the connection pool out from under the next minter
  /// built over the same one.
  void close() {
    if (_ownsClient) _client.close();
  }

  Future<Map<String, Object?>> _send(
    String method,
    Uri url, {
    String? body,
    Map<String, String> extraHeaders = const {},
  }) async {
    var response = await _once(
      method,
      url,
      await _bearer(),
      body,
      extraHeaders,
    );
    if (response.statusCode == 401) {
      // The backstop for every expiry the clock cannot predict: a token that
      // is not a JWT, a cache that restated `expires_in`, a clock that
      // disagrees with the issuer's, a token revoked early. Once, never in a
      // loop -- a replay refused again means the credentials are wrong, and
      // the decode below says so.
      _accessToken = null;
      _accessTokenDeadline = DateTime.utc(1970);
      response = await _once(method, url, await _bearer(), body, extraHeaders);
    }
    return _decode(method, url, response);
  }

  Future<http.Response> _once(
    String method,
    Uri url,
    String bearer,
    String? body,
    Map<String, String> extraHeaders,
  ) {
    final headers = {
      'User-Agent': userAgent,
      'Authorization': 'Bearer $bearer',
      'PayCross-Version': paycrossVersion,
      ...extraHeaders,
    };
    final request = http.Request(method, url)..headers.addAll(headers);
    if (body != null) request.body = body;
    return _run(request);
  }

  Future<http.Response> _run(http.Request request) async {
    try {
      // One deadline over both legs. `send` completes when the headers land,
      // so a deadline on it alone leaves the body read untimed and a phone
      // that lost signal mid-response waiting as long as the socket lives.
      return await _client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(_timeout);
    } catch (error) {
      // The exception type is safe to name; its message is not always, so it
      // goes through the same scrub as a response body.
      throw MinterError(
        '${request.method} ${request.url.path} failed: '
        '${error.runtimeType}: ${_safeToEcho('$error')}',
      );
    }
  }

  Future<String> _bearer() {
    final cached = _accessToken;
    if (cached != null && _now().isBefore(_accessTokenDeadline)) {
      return Future.value(cached);
    }
    // One fetch however many callers are waiting on it. Two taps in a row
    // would otherwise mint two tokens, and the second would evict the first
    // while a request was still on its way out carrying it.
    return _bearerInFlight ??= _fetchBearer().whenComplete(
      () => _bearerInFlight = null,
    );
  }

  Future<String> _fetchBearer() async {
    final basic = base64.encode(
      utf8.encode('${_credentials.clientId}:${_credentials.clientSecret}'),
    );
    final url = Uri.parse(tokenUrl);
    final request = http.Request('POST', url)
      ..headers.addAll({
        'User-Agent': userAgent,
        'Authorization': 'Basic $basic',
        'Content-Type': 'application/x-www-form-urlencoded',
      })
      ..body = 'grant_type=client_credentials';

    final raw = _decode('POST', url, await _run(request));
    final token = raw['access_token'];
    if (token is! String) {
      throw const MinterError('The token endpoint returned no access_token.');
    }
    _accessToken = token;
    _accessTokenDeadline = _deadlineFor(token, raw['expires_in']);
    return token;
  }

  /// When to stop reusing a freshly issued token.
  ///
  /// The JWT's own `exp` wins over `expires_in`, because only one of them
  /// describes *this* token: the M2M endpoint sits behind a cache, and a
  /// cached hit arrives with a full `expires_in` restated as though the
  /// token had just been minted, so a client starting partway through a
  /// token's life is told it has the whole thing (cognito-m2m#1). `exp` is
  /// inside the signed payload and the cache does not rewrite it.
  DateTime _deadlineFor(String token, Object? expiresIn) {
    // No clock-skew guard, unlike `sandbox.py`'s IMPLAUSIBLE_EXP_AGE_SECONDS:
    // a phone whose clock is wrong reads every `exp` as long past and pays one
    // extra token round trip per call for it, which is never a failed payment.
    final expiry = jwtExpiry(token);
    if (expiry != null) return expiry.subtract(tokenRefreshMargin);
    final seconds = expiresIn is num ? expiresIn.toInt() : 3600;
    return _now().add(Duration(seconds: seconds) - tokenRefreshMargin);
  }

  Map<String, Object?> _decode(String method, Uri url, http.Response response) {
    final text = response.body;
    if (_looksLikeHtml(text)) {
      throw MinterError(
        '$method ${url.path}: blocked at the edge (Cloudflare) — '
        'status ${response.statusCode}',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw MinterError(
        '$method ${url.path} -> HTTP ${response.statusCode}: '
        '${_safeToEcho(text)}',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw MinterError(
        '$method ${url.path} -> HTTP ${response.statusCode}, '
        'body is not JSON: ${_safeToEcho(text)}',
      );
    }
    if (decoded is! Map) {
      throw MinterError(
        '$method ${url.path} did not return an object: ${_safeToEcho(text)}',
      );
    }
    return {for (final entry in decoded.entries) '${entry.key}': entry.value};
  }
}

/// Substitutes the two placeholders the preset bodies carry.
///
/// Takes its clock so a minter's own `now` reaches the body: a test that
/// pins the reference it sent needs the same stamp twice, and the editor
/// calls this directly.
String substitutePlaceholders(
  String body, {
  DateTime Function() now = DateTime.now,
}) => body
    .replaceAll('{{timestamp}}', '${now().millisecondsSinceEpoch}')
    .replaceAll('{{uuid}}', randomUuidV4());

bool _looksLikeHtml(String text) {
  final head = text.trimLeft().toLowerCase();
  return head.startsWith('<!doctype html') || head.startsWith('<html');
}

final RegExp _jwtShape = RegExp(
  r'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+',
);

/// Renders a response for an error message with every token dropped and the
/// text cut short. Whole session resources reach here, not just refusals.
///
/// Two branches, the same two `sandbox.py`'s `_safe_to_echo` has. A body that
/// parses is scrubbed by key first, so a token is dropped whatever shape its
/// value has -- an opaque `saved_token` is invisible to the mask below.
/// Anything that does not parse -- a transport failure's message, a gateway's
/// plain-text refusal -- has only the mask.
///
/// The key pass is not optional here the way it nearly is in the Python: what
/// this text reaches is History and the bug-report block, so it is an
/// artifact rather than a line in a run log.
String _safeToEcho(String text) {
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    return _maskAndTrim(text);
  }
  return _maskAndTrim(jsonEncode(scrubResource(decoded)));
}

String _maskAndTrim(String text) {
  final masked = text.replaceAll(_jwtShape, '<redacted>');
  return masked.length <= 400 ? masked : '${masked.substring(0, 400)}…';
}
