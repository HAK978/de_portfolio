// Tests for PriceHistoryService: Steam returns price history in the
// account's wallet currency, so the chart is only right if the currency
// is detected and converted correctly. The old code assumed every
// account was INR, which shrank USD prices ~85x.

import 'dart:convert';
import 'dart:io';

import 'package:de_portfolio/services/price_history_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A pricehistory response in the given wallet currency.
String historyJson({String prefix = r'$', String suffix = '', List<List<Object>>? prices}) => jsonEncode({
      'success': true,
      'price_prefix': prefix,
      'price_suffix': suffix,
      'prices': prices ??
          [
            ['Mar 21 2026 01: +0', 4.0, '10'],
            ['Mar 20 2026 01: +0', 3.5, '150'],
          ],
    });

/// Fake network: pricehistory answers with [history]; the exchange-rate
/// API answers with [rates] (or fails if null). Records requested hosts.
MockClient fakeNetwork({required String history, Map<String, num>? rates, List<String>? requested}) =>
    MockClient((request) async {
      requested?.add(request.url.host);
      if (request.url.host == 'open.er-api.com') {
        return rates == null
            ? http.Response('unavailable', 503)
            : http.Response(jsonEncode({'result': 'success', 'rates': rates}), 200);
      }
      expect(request.headers['Cookie'], 'steamLoginSecure=cookie');
      return http.Response(history, 200, headers: {'content-type': 'application/json; charset=utf-8'});
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  late Directory docs;

  setUp(() {
    PriceHistoryService.clearRateCache();
    // Each test gets its own empty "documents" folder for the caches.
    docs = Directory.systemTemp.createTempSync('price_history_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => docs.path);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    docs.deleteSync(recursive: true);
  });

  PriceHistoryService service(http.Client client) =>
      PriceHistoryService(steamLoginCookie: 'cookie', client: client);

  group('currencyFromSymbols', () {
    test('recognises prefix and suffix symbols', () {
      expect(PriceHistoryService.currencyFromSymbols(r'$', ''), 'USD');
      expect(PriceHistoryService.currencyFromSymbols('₹ ', ''), 'INR');
      expect(PriceHistoryService.currencyFromSymbols('', '€'), 'EUR');
      expect(PriceHistoryService.currencyFromSymbols(r'CDN$ ', ''), 'CAD');
      expect(PriceHistoryService.currencyFromSymbols('', ' pуб.'), 'RUB');
    });

    test('refuses to guess ambiguous or unknown symbols', () {
      expect(PriceHistoryService.currencyFromSymbols('¥ ', ''), isNull); // CNY or JPY
      expect(PriceHistoryService.currencyFromSymbols('', ''), isNull);
      expect(PriceHistoryService.currencyFromSymbols(null, null), isNull);
    });
  });

  group('fetchHistory', () {
    test('USD wallets are not converted and need no exchange rate', () async {
      final hosts = <String>[];
      final points = await service(fakeNetwork(history: historyJson(), requested: hosts))
          .fetchHistory('AK-47 | Redline (Field-Tested)');

      expect(points!.map((p) => p.price), [3.5, 4.0]); // sorted oldest first
      expect(points.first.date, DateTime.utc(2026, 3, 20, 1));
      expect(points.first.volume, 150);
      expect(hosts, isNot(contains('open.er-api.com')));
    });

    test('INR wallets are converted with the live rate', () async {
      final points = await service(fakeNetwork(
        history: historyJson(prefix: '₹ ', prices: [['Mar 20 2026 01: +0', 160, '1']]),
        rates: {'USD': 1, 'INR': 80},
      )).fetchHistory('x');

      expect(points!.single.price, 2.0);
    });

    test('INR falls back to an approximate rate if the rates API is down', () async {
      final points = await service(fakeNetwork(
        history: historyJson(prefix: '₹ ', prices: [['Mar 20 2026 01: +0', 170, '1']]),
      )).fetchHistory('x');

      expect(points!.single.price, 2.0); // 170 / 85
    });

    test('other currencies convert when the rate is known, else show nothing', () async {
      final eur = historyJson(prefix: '', suffix: '€', prices: [['Mar 20 2026 01: +0', 9, '1']]);
      expect((await service(fakeNetwork(history: eur, rates: {'EUR': 0.9})).fetchHistory('x'))!.single.price,
          closeTo(10, 1e-9));

      // Same wallet, but no rates available (memory and disk caches cleared).
      PriceHistoryService.clearRateCache();
      File('${docs.path}/exchange_rates.json').deleteSync();
      expect(await service(fakeNetwork(history: eur)).fetchHistory('another item'), isNull);
    });

    test('an unrecognised wallet currency shows no chart rather than wrong prices', () async {
      final points = await service(fakeNetwork(history: historyJson(prefix: '¥ '), rates: {'JPY': 150}))
          .fetchHistory('x');
      expect(points, isNull);
    });

    test('malformed entries are skipped', () async {
      final points = await service(fakeNetwork(history: historyJson(prices: [
        ['Mar 20 2026 01: +0', 3.5, '1'],
        ['not a date', 1.0, '1'],
        ['Mar 21 2026 01: +0', 'n/a', '1'],
        ['Mar 22 2026 01: +0'],
      ]))).fetchHistory('x');
      expect(points!.map((p) => p.price), [3.5]);
    });

    test('no cookie means no request at all', () async {
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return http.Response('{}', 200);
      });
      expect(await PriceHistoryService(client: client).fetchHistory('x'), isNull);
      expect(requests, 0);
    });

    test('a second fetch is served from the cache, with no network', () async {
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        return http.Response(historyJson(), 200);
      });
      final first = await service(client).fetchHistory('AK-47 | Redline (Field-Tested)');
      final second = await service(client).fetchHistory('AK-47 | Redline (Field-Tested)');
      expect(requests, 1);
      expect(second!.map((p) => p.price), first!.map((p) => p.price));
    });

    test('Steam refusing the request yields null', () async {
      for (final response in [
        http.Response('{"success":false}', 200),
        http.Response('Too Many Requests', 429),
      ]) {
        final client = MockClient((_) async => response);
        expect(await service(client).fetchHistory('x'), isNull);
      }
    });
  });
}
