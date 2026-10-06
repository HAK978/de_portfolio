import 'dart:convert';

import 'package:de_portfolio/models/cs2_item.dart';
import 'package:de_portfolio/services/steam_api_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class TestSteamService extends SteamApiService {
  TestSteamService(http.Client client) : super(client: client);
  List<CS2Item>? saved;
  @override
  Future<void> saveInventoryCache(String steamId, List<CS2Item> items) async {
    saved = items;
  }
}

Map<String, dynamic> page(List<String> names) => {
  'success': 1,
  'assets': [for (final name in names) {'classid': name, 'instanceid': '0', 'amount': '1'}],
  'descriptions': [for (final name in names) {
    'classid': name, 'instanceid': '0', 'name': name, 'market_hash_name': name,
  }],
};

void main() {
  test('group IDs stay stable when Steam changes inventory order', () async {
    var names = ['AK-47 | Redline', 'Music Kit / Example'];
    final service = TestSteamService(MockClient((_) async => http.Response(jsonEncode(page(names)), 200)));
    final first = await service.fetchInventory('account');
    names = names.reversed.toList();
    final next = await service.fetchInventory('account');
    expect({for (final i in first) i.name: i.id}, {for (final i in next) i.name: i.id});
    expect(first.every((i) => !i.id.contains('/')), isTrue);
  });

  test('missing item descriptions fail without caching a partial inventory', () async {
    final data = page(['a'])..['descriptions'] = [];
    final service = TestSteamService(MockClient((_) async => http.Response(jsonEncode(data), 200)));
    await expectLater(service.fetchInventory('account'), throwsFormatException);
    expect(service.saved, isNull);
  });

  test('missing pagination cursor fails instead of repeating the first page', () async {
    final data = page(['a'])..['more_items'] = 1;
    final service = TestSteamService(MockClient((_) async => http.Response(jsonEncode(data), 200)));
    await expectLater(service.fetchInventory('account'), throwsFormatException);
    expect(service.saved, isNull);
  });

  test('cancelled fetch never overwrites a complete cached inventory', () async {
    late TestSteamService service;
    service = TestSteamService(MockClient((_) async {
      service.cancelFetch();
      return http.Response(jsonEncode(page(['a'])), 200);
    }));
    await service.fetchInventory('account');
    expect(service.wasCancelled, isTrue);
    expect(service.saved, isNull);
  });

  test('successful empty inventory can be cached', () async {
    final service = TestSteamService(MockClient((_) async => http.Response('{"success":1}', 200)));
    expect(await service.fetchInventory('account'), isEmpty);
    expect(service.saved, isEmpty);
  });
}
