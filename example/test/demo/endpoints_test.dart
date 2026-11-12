import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/endpoints.dart';

void main() {
  test('the two environments are two', () {
    expect(liveEndpoints.tokenUrl, isNot(testEndpoints.tokenUrl));
    expect(liveEndpoints.sessionsUrl, isNot(testEndpoints.sessionsUrl));
  });

  test('neither environment reaches the other one host', () {
    for (final url in [testEndpoints.tokenUrl, testEndpoints.sessionsUrl]) {
      expect(Uri.parse(url).host, contains('test'), reason: url);
    }
    for (final url in [liveEndpoints.tokenUrl, liveEndpoints.sessionsUrl]) {
      expect(Uri.parse(url).host, isNot(contains('test')), reason: url);
    }
  });

  test('both token urls carry the scope the endpoint requires', () {
    for (final url in [testEndpoints.tokenUrl, liveEndpoints.tokenUrl]) {
      expect(
        Uri.parse(url).queryParameters['scope'],
        'paycross/payments',
        reason: url,
      );
    }
  });

  test('both session urls are the spelling the merchant API routes', () {
    for (final url in [testEndpoints.sessionsUrl, liveEndpoints.sessionsUrl]) {
      expect(Uri.parse(url).path, '/payment-sessions', reason: url);
    }
  });

  test('every url is https', () {
    for (final url in [
      testEndpoints.tokenUrl,
      testEndpoints.sessionsUrl,
      liveEndpoints.tokenUrl,
      liveEndpoints.sessionsUrl,
    ]) {
      expect(Uri.parse(url).scheme, 'https', reason: url);
    }
  });
}
