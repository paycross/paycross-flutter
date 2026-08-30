import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:paycross_demo/demo/minter.dart';
import 'package:paycross_demo/demo/secrets.dart';

const _credentials = Credentials(
  clientId: 'demo-client',
  clientSecret: 'sh-not-a-real-secret-4d2',
);

/// A JWT whose payload carries the given `exp`. Unsigned -- the minter reads
/// the claim for scheduling and never verifies it, which is exactly what
/// `sandbox.py:_jwt_exp` documents.
String jwtExpiring(DateTime at) {
  String segment(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final head = segment({'alg': 'RS256', 'typ': 'JWT'});
  final body = segment({'exp': at.millisecondsSinceEpoch ~/ 1000});
  return '$head.$body.notasignature';
}

void main() {
  late DateTime clock;
  late List<http.Request> sent;

  setUp(() {
    clock = DateTime.utc(2026, 8, 29, 12);
    sent = <http.Request>[];
  });

  /// Records every request and answers from `respond`.
  MockClient recording(
    http.Response Function(http.Request request, int index) respond,
  ) => MockClient((request) async {
    sent.add(request);
    return respond(request, sent.length - 1);
  });

  http.Response tokenResponse(DateTime expiry) => http.Response(
    jsonEncode({'access_token': jwtExpiring(expiry), 'expires_in': 3600}),
    200,
  );

  http.Response sessionResponse() => http.Response(
    jsonEncode({
      'id': 'sess-1',
      'session_token': 'eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxIn0.sig',
      'checkout_url': 'https://checkout.test-pay-cross.com/pay?session=abc',
    }),
    200,
  );

  Minter minterOver(http.Client client) => Minter(
    credentials: _credentials,
    client: client,
    now: () => clock,
    newIdempotencyKey: () => 'idem-${sent.length}',
  );

  group('the bearer token', () {
    test('is fetched once and reused inside its lifetime', () async {
      final minter = minterOver(
        recording((request, index) {
          if (request.url.path.endsWith('/token')) {
            return tokenResponse(clock.add(const Duration(hours: 1)));
          }
          return sessionResponse();
        }),
      );

      await minter.mint('{"amount":1000}');
      await minter.mint('{"amount":1000}');

      final tokenCalls = sent
          .where((r) => r.url.path.endsWith('/token'))
          .length;
      expect(tokenCalls, 1);
    });

    test('is replaced from the JWT exp, never from expires_in', () async {
      // The token endpoint sits behind an API-Gateway cache that restates a
      // full expires_in on a cached hit (cognito-m2m#1). This token is
      // already 59 minutes old: expires_in says an hour of life, exp says
      // one minute, and only exp is right.
      final minter = minterOver(
        recording((request, index) {
          if (request.url.path.endsWith('/token')) {
            return tokenResponse(clock.add(const Duration(minutes: 1)));
          }
          return sessionResponse();
        }),
      );

      await minter.mint('{"amount":1000}');
      await minter.mint('{"amount":1000}');

      final tokenCalls = sent
          .where((r) => r.url.path.endsWith('/token'))
          .length;
      expect(tokenCalls, 2);
    });

    test('falls back to expires_in when the token is not a JWT', () async {
      var tokenCalls = 0;
      final minter = Minter(
        credentials: _credentials,
        now: () => clock,
        newIdempotencyKey: () => 'idem',
        client: MockClient((request) async {
          if (request.url.path.endsWith('/token')) {
            tokenCalls++;
            return http.Response(
              jsonEncode({'access_token': 'opaque', 'expires_in': 3600}),
              200,
            );
          }
          return sessionResponse();
        }),
      );

      await minter.mint('{"amount":1000}');
      clock = clock.add(const Duration(minutes: 30));
      await minter.mint('{"amount":1000}');

      expect(tokenCalls, 1);
    });

    test('is replaced a full margin before it dies', () async {
      var tokenCalls = 0;
      final minter = Minter(
        credentials: _credentials,
        now: () => clock,
        newIdempotencyKey: () => 'idem',
        client: MockClient((request) async {
          if (request.url.path.endsWith('/token')) {
            tokenCalls++;
            return tokenResponse(clock.add(const Duration(hours: 1)));
          }
          return sessionResponse();
        }),
      );

      await minter.mint('{"amount":1000}');
      // 3600 - 240 = 3360 s of usable life. One second past it refetches.
      clock = clock.add(const Duration(seconds: 3361));
      await minter.mint('{"amount":1000}');

      expect(tokenCalls, 2);
    });
  });

  group('a 401', () {
    test('refetches the token and replays with the same key', () async {
      final minter = minterOver(
        recording((request, index) {
          if (request.url.path.endsWith('/token')) {
            return tokenResponse(clock.add(const Duration(hours: 1)));
          }
          // First session attempt is refused; the replay succeeds.
          return index == 1
              ? http.Response('{"message":"Unauthorized"}', 401)
              : sessionResponse();
        }),
      );

      final minted = await minter.mint('{"amount":1000}');

      expect(minted.id, 'sess-1');
      final sessionCalls = sent
          .where((r) => !r.url.path.endsWith('/token'))
          .toList();
      expect(sessionCalls, hasLength(2));
      // Regenerating the key here would bill a second live session.
      expect(
        sessionCalls.first.headers['Idempotency-Key'],
        sessionCalls.last.headers['Idempotency-Key'],
      );
      expect(sent.where((r) => r.url.path.endsWith('/token')), hasLength(2));
    });

    test('is not retried twice', () async {
      final minter = minterOver(
        recording((request, index) {
          if (request.url.path.endsWith('/token')) {
            return tokenResponse(clock.add(const Duration(hours: 1)));
          }
          return http.Response('{"message":"Unauthorized"}', 401);
        }),
      );

      await expectLater(
        minter.mint('{"amount":1000}'),
        throwsA(isA<MinterError>()),
      );
      expect(sent.where((r) => !r.url.path.endsWith('/token')), hasLength(2));
    });
  });

  group('what leaves the module', () {
    test('no thrown error carries the client secret', () async {
      final minter = minterOver(
        recording((request, index) => http.Response('{"message":"nope"}', 500)),
      );

      try {
        await minter.mint('{"amount":1000}');
        fail('expected a MinterError');
      } on MinterError catch (error) {
        expect(error.toString(), isNot(contains(_credentials.clientSecret)));
        expect(error.toString(), isNot(contains(_credentials.clientId)));
      }
    });

    test('the read-back drops token values by key, at any depth', () async {
      final minter = minterOver(
        recording((request, index) {
          if (request.url.path.endsWith('/token')) {
            return tokenResponse(clock.add(const Duration(hours: 1)));
          }
          return http.Response(
            jsonEncode({
              'id': 'sess-1',
              'status': 'open',
              // The merchant API re-mints one of these on every read of an
              // open session, so it is not the token we already hold.
              'session_token': 'eyJhbGciOiJSUzI1NiJ9.eyJhIjoxfQ.other',
              'checkout_url':
                  'https://checkout.test-pay-cross.com/pay?session=abc&x=1',
              'saved_cards': [
                {'saved_token': 'tok_live_1', 'brand': 'visa'},
              ],
            }),
            200,
          );
        }),
      );

      final session = await minter.read('sess-1');

      final rendered = jsonEncode(session);
      expect(rendered, isNot(contains('eyJhbGciOiJSUzI1NiJ9')));
      expect(rendered, isNot(contains('tok_live_1')));
      expect(rendered, isNot(contains('session=abc')));
      expect(session['status'], 'open');
      expect((session['saved_cards'] as List).first['brand'], 'visa');
    });

    test('a refusal echoes no token value, JWT-shaped or not', () async {
      final minter = minterOver(
        recording((request, index) {
          if (request.url.path.endsWith('/token')) {
            return tokenResponse(clock.add(const Duration(hours: 1)));
          }
          return http.Response(
            jsonEncode({
              'message': 'that card is not enrolled',
              'session_token': 'eyJhbGciOiJSUzI1NiJ9.eyJhIjoxfQ.other',
              // Opaque, so the JWT mask alone cannot see it. History keeps
              // this text and the bug-report block quotes it.
              'saved_cards': [
                {'saved_token': 'tok_live_1', 'brand': 'visa'},
              ],
            }),
            422,
          );
        }),
      );

      try {
        await minter.mint('{"amount":1000}');
        fail('expected a MinterError');
      } on MinterError catch (error) {
        expect(error.message, isNot(contains('tok_live_1')));
        expect(error.message, isNot(contains('eyJhbGciOiJSUzI1NiJ9')));
        // What is left has to stay worth reading, or the refusal is no use
        // in a bug report.
        expect(error.message, contains('422'));
        expect(error.message, contains('not enrolled'));
        expect(error.message, contains('visa'));
      }
    });

    test('a refusal that is not JSON keeps the JWT mask', () async {
      final minter = minterOver(
        recording((request, index) {
          if (request.url.path.endsWith('/token')) {
            return tokenResponse(clock.add(const Duration(hours: 1)));
          }
          return http.Response(
            'upstream connect failure for '
            'eyJhbGciOiJSUzI1NiJ9.eyJhIjoxfQ.other',
            502,
          );
        }),
      );

      try {
        await minter.mint('{"amount":1000}');
        fail('expected a MinterError');
      } on MinterError catch (error) {
        expect(error.message, isNot(contains('eyJhbGciOiJSUzI1NiJ9')));
        expect(error.message, contains('upstream connect failure'));
      }
    });

    test('an HTML refusal is reported as the edge, not as bad JSON', () async {
      final minter = minterOver(
        recording((request, index) {
          if (request.url.path.endsWith('/token')) {
            return tokenResponse(clock.add(const Duration(hours: 1)));
          }
          return http.Response(
            '<!DOCTYPE html><html><head><title>Attention Required! '
            '| Cloudflare</title></head><body>...</body></html>',
            403,
          );
        }),
      );

      await expectLater(
        minter.mint('{"amount":1000}'),
        throwsA(
          isA<MinterError>().having(
            (e) => e.message,
            'message',
            allOf(contains('blocked at the edge'), contains('403')),
          ),
        ),
      );
    });
  });

  group('the request itself', () {
    test('sends the version header, a browser UA and basic auth', () async {
      final minter = minterOver(
        recording((request, index) {
          if (request.url.path.endsWith('/token')) {
            return tokenResponse(clock.add(const Duration(hours: 1)));
          }
          return sessionResponse();
        }),
      );

      await minter.mint('{"amount":1000}');

      final token = sent.firstWhere((r) => r.url.path.endsWith('/token'));
      expect(
        token.headers['authorization'],
        'Basic ${base64.encode(utf8.encode('demo-client:${_credentials.clientSecret}'))}',
      );
      expect(token.body, 'grant_type=client_credentials');

      final session = sent.firstWhere((r) => !r.url.path.endsWith('/token'));
      expect(session.headers['paycross-version'], isNotEmpty);
      expect(session.headers['user-agent'], contains('Mozilla/5.0'));
      expect(session.url.path, endsWith('/payment-sessions'));
    });

    test('substitutes the body placeholders the presets use', () async {
      final minter = minterOver(
        recording((request, index) {
          if (request.url.path.endsWith('/token')) {
            return tokenResponse(clock.add(const Duration(hours: 1)));
          }
          return sessionResponse();
        }),
      );

      final minted = await minter.mint(
        '{"merchant_reference":"DEMO-{{timestamp}}","x":"{{uuid}}"}',
      );

      expect(minted.sentBody, isNot(contains('{{timestamp}}')));
      expect(minted.sentBody, isNot(contains('{{uuid}}')));
      expect(minted.sentBody, contains('DEMO-'));
    });

    test('a body that is not an object is refused before it is sent', () {
      final minter = minterOver(
        recording((request, index) => sessionResponse()),
      );

      expect(() => minter.mint('not json at all'), throwsA(isA<MinterError>()));
      expect(sent, isEmpty);
    });

    test('a mint that returns no session_token says so', () async {
      final minter = minterOver(
        recording((request, index) {
          if (request.url.path.endsWith('/token')) {
            return tokenResponse(clock.add(const Duration(hours: 1)));
          }
          return http.Response(jsonEncode({'id': 'sess-1'}), 200);
        }),
      );

      await expectLater(
        minter.mint('{"amount":1000}'),
        throwsA(
          isA<MinterError>().having(
            (e) => e.message,
            'message',
            contains('no session_token'),
          ),
        ),
      );
    });
  });
}
