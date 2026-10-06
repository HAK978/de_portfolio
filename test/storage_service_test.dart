// Contract tests for the app's storage-service client: how it reads the
// VM's responses (see storage-service/app.js for the server side).

import 'dart:convert';

import 'package:de_portfolio/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

StorageService serviceReplying(http.Response Function(http.Request) reply, {String? apiKey = 'key'}) =>
    StorageService(baseUrl: 'https://vm.test', apiKey: apiKey, client: MockClient((r) async => reply(r)));

http.Response json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

void main() {
  group('getStatus', () {
    test('parses connection state and the VM\'s Steam account', () async {
      final status = await serviceReplying((_) => json({
            'steam': true,
            'gc': false,
            'displayName': 'Owner',
            'steamId': '76561198000000001',
          })).getStatus();

      expect(status.reachable, isTrue);
      expect(status.steamConnected, isTrue);
      expect(status.isReady, isFalse); // GC is on-demand
      expect(status.steamId, '76561198000000001');
    });

    test('a wrong API key is reported as such, not as "unreachable"', () async {
      final status = await serviceReplying((_) => json({'error': 'Invalid or missing API key'}, 401)).getStatus();
      expect(status.reachable, isTrue);
      expect(status.unauthorized, isTrue);
    });

    test('network failures mean unreachable, without throwing', () async {
      final service = StorageService(
        baseUrl: 'https://vm.test',
        client: MockClient((_) async => throw http.ClientException('connection refused')),
      );
      final status = await service.getStatus();
      expect(status.reachable, isFalse);
    });
  });

  test('sends the API key header only when one is set', () async {
    final seen = <String?>[];
    await serviceReplying((r) {
      seen.add(r.headers['X-Api-Key']);
      return json({'steam': true, 'gc': true});
    }).getStatus();
    await serviceReplying((r) {
      seen.add(r.headers['X-Api-Key']);
      return json({'steam': true, 'gc': true});
    }, apiKey: null).getStatus();
    expect(seen, ['key', null]);
  });

  group('errors', () {
    test('surface the VM\'s own message (e.g. CS2 is being played)', () async {
      final service = serviceReplying((_) => json({'error': 'Real Steam client is playing CS2 — yielded to it'}, 503));
      await expectLater(
        service.getCaskets(),
        throwsA(predicate((e) => e.toString().contains('playing CS2'))),
      );
    });

    test('fall back to the status code when the body is not JSON', () async {
      final service = serviceReplying((_) => http.Response('<html>Bad Gateway</html>', 502));
      await expectLater(
        service.getCasketContents('123'),
        throwsA(predicate((e) => e.toString().contains('(502)'))),
      );
    });
  });

  test('casket contents become CS2Items located in storage', () async {
    final items = await serviceReplying((r) {
      expect(r.url.path, '/storage/123');
      return json({
        'casketId': '123',
        'itemCount': 1,
        'items': [
          {
            'id': '9',
            'name': '★ StatTrak™ Karambit | Doppler',
            'marketHashName': '★ StatTrak™ Karambit | Doppler (Factory New)',
            'wear': 'Factory New',
            'rarity': 'Covert',
            'isStatTrak': true,
            'paintWear': 0.01,
          },
        ],
      });
    }).getCasketContents('123');

    final knife = items.single;
    expect(knife.location, 'storage');
    expect(knife.marketHashName, '★ StatTrak™ Karambit | Doppler (Factory New)');
    expect(knife.weaponType, 'Karambit');
    expect(knife.skinName, 'Doppler');
    expect(knife.floatValue, 0.01);
    expect(knife.isStatTrak, isTrue);
  });

  test('inventory floats are grouped by market hash name', () async {
    final floats = await serviceReplying((_) => json({
          'itemCount': 1,
          'floats': {
            'AK-47 | Redline (Field-Tested)': [
              {'assetId': '1', 'floatValue': 0.2, 'paintSeed': 42, 'paintIndex': 282},
              {'assetId': '2', 'floatValue': 0.31, 'paintSeed': null, 'paintIndex': null},
            ],
          },
        })).getInventoryFloats();

    final redlines = floats['AK-47 | Redline (Field-Tested)']!;
    expect(redlines.map((f) => f.floatValue), [0.2, 0.31]);
    expect(redlines.first.paintSeed, 42);
  });
}
