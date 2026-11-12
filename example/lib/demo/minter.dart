// ignore_for_file: prefer_initializing_formals
// readability call, not a limitation: an `// ignore:` on its own line

import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'endpoints.dart';
import 'presets.dart';
import 'secrets.dart';

const Duration tokenRefreshMargin = Duration(seconds: 240);

const Duration _requestTimeout = Duration(seconds: 60);

const Set<String> _tokenKeys = {'session_token', 'saved_token', 'used_token'};

class MinterError implements Exception {
  const MinterError(this.message);

  final String message;

  @override
  String toString() => message;
}

class MintedSession {
  const MintedSession({
    required this.id,
    required this.token,
    required this.sentBody,
    this.checkoutUrl,
  });

  final String id;
  final String token;

  final String? checkoutUrl;

  final String sentBody;
}

String randomUuidV4() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

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

Future<String> mintThrowawaySession(
  Credentials credentials, {
  http.Client? client,
}) async {
  final minter = Minter(credentials: credentials, client: client);
  try {
    final minted = await minter.mint(verifyProbeBody);
    return 'Minted session ${minted.id}.';
  } finally {
    minter.close();
  }
}

class Minter {
  Minter({
    required Credentials credentials,
    http.Client? client,
    DateTime Function() now = DateTime.now,
    String Function() newIdempotencyKey = randomUuidV4,
    Duration timeout = _requestTimeout,
    Endpoints endpoints = testEndpoints,
  }) : _credentials = credentials,
       _ownsClient = client == null,
       _client = client ?? http.Client(),
       _now = now,
       _newIdempotencyKey = newIdempotencyKey,
       _timeout = timeout,
       _endpoints = endpoints;

  final Credentials _credentials;
  final http.Client _client;
  final bool _ownsClient;
  final DateTime Function() _now;
  final String Function() _newIdempotencyKey;
  final Duration _timeout;

  final Endpoints _endpoints;

  String? _accessToken;
  DateTime _accessTokenDeadline = DateTime.utc(1970);
  Future<String>? _bearerInFlight;

  Future<MintedSession> mint(String body) async {
    final sent = substitutePlaceholders(body, now: _now);
    final Object? decoded;
    try {
      decoded = jsonDecode(sent);
    } on FormatException catch (error) {
      throw MinterError('The session body is not JSON: ${error.message}');
    }
    if (decoded is! Map) {
      throw const MinterError('The session body must be a JSON object.');
    }

    final raw = await _send(
      'POST',
      Uri.parse(_endpoints.sessionsUrl),
      body: sent,
      extraHeaders: {
        'Content-Type': 'application/json',
        'Idempotency-Key': _newIdempotencyKey(),
      },
    );

    final id = raw['id'];
    final token = raw['session_token'];
    if (id is! String || token is! String) {
      throw const MinterError('The mint returned no session_token.');
    }
    final checkoutUrl = raw['checkout_url'];
    return MintedSession(
      id: id,
      token: token,
      sentBody: sent,
      checkoutUrl: checkoutUrl is String && checkoutUrl.isNotEmpty
          ? checkoutUrl
          : null,
    );
  }

  Future<Map<String, Object?>> read(String sessionId) async {
    final raw = await _send(
      'GET',
      Uri.parse('${_endpoints.sessionsUrl}/$sessionId'),
    );
    return scrubResource(raw)! as Map<String, Object?>;
  }

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
      return await _client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(_timeout);
    } catch (error) {
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
    return _bearerInFlight ??= _fetchBearer().whenComplete(
      () => _bearerInFlight = null,
    );
  }

  Future<String> _fetchBearer() async {
    final basic = base64.encode(
      utf8.encode('${_credentials.clientId}:${_credentials.clientSecret}'),
    );
    final url = Uri.parse(_endpoints.tokenUrl);
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

  DateTime _deadlineFor(String token, Object? expiresIn) {
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

String _safeToEcho(String text) {
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    return maskAndTrim(text);
  }
  return maskAndTrim(jsonEncode(scrubResource(decoded)));
}

String maskAndTrim(String text) {
  final masked = text.replaceAll(_jwtShape, '<redacted>');
  return masked.length <= 400 ? masked : '${masked.substring(0, 400)}…';
}
