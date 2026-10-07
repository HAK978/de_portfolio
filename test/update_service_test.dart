// Tests for the in-app updater's download side. An updater delivers
// code, so these focus on what it refuses: other sources, unverifiable
// releases, corrupted or truncated downloads.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:de_portfolio/services/update_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const base = 'https://github.com/HAK978/de_portfolio/releases/download/v1.3.1';

Map<String, dynamic> releaseJson({
  String tag = 'v1.3.1',
  String apkUrl = '$base/app-release.apk',
  String? checksumUrl = '$base/app-release.apk.sha256',
}) => {
      'tag_name': tag,
      'html_url': 'https://github.com/HAK978/de_portfolio/releases/tag/$tag',
      'body': 'Bug fixes',
      'assets': [
        {'name': 'app-release.apk', 'browser_download_url': apkUrl},
        if (checksumUrl != null) {'name': 'app-release.apk.sha256', 'browser_download_url': checksumUrl},
      ],
    };

UpdateService serviceReplying(http.Response Function(http.Request) reply) =>
    UpdateService(client: MockClient((request) async => reply(request)));

AppRelease release131() => AppRelease(
      version: '1.3.1',
      apkUrl: Uri.parse('$base/app-release.apk'),
      checksumUrl: Uri.parse('$base/app-release.apk.sha256'),
      notes: '',
      pageUrl: Uri.parse('https://github.com/HAK978/de_portfolio/releases'),
    );

void main() {
  group('isNewer', () {
    test('compares versions numerically, not as text', () {
      expect(UpdateService.isNewer('1.3.1', '1.3.0'), isTrue);
      expect(UpdateService.isNewer('1.10.0', '1.9.9'), isTrue);
      expect(UpdateService.isNewer('2.0.0', '1.99.99'), isTrue);
      expect(UpdateService.isNewer('1.3.0', '1.3.0'), isFalse);
      expect(UpdateService.isNewer('1.2.9', '1.3.0'), isFalse);
    });

    test('ignores the build number and never offers pre-releases or junk', () {
      expect(UpdateService.isNewer('1.3.1', '1.3.0+6'), isTrue);
      expect(UpdateService.isNewer('1.4.0-beta', '1.3.0'), isFalse);
      expect(UpdateService.isNewer('latest', '1.3.0'), isFalse);
    });
  });

  group('latestRelease', () {
    test('parses the release and its assets', () async {
      final release = await serviceReplying((r) {
        expect(r.url.toString(), 'https://api.github.com/repos/HAK978/de_portfolio/releases/latest');
        return http.Response(jsonEncode(releaseJson()), 200);
      }).latestRelease();

      expect(release!.version, '1.3.1');
      expect(release.apkUrl.toString(), '$base/app-release.apk');
      expect(release.checksumUrl.toString(), '$base/app-release.apk.sha256');
      expect(release.notes, 'Bug fixes');
    });

    test('ignores download links that aren\'t this repository\'s releases', () async {
      for (final url in [
        'https://evil.example/app-release.apk',
        'http://github.com/HAK978/de_portfolio/releases/download/v1.3.1/app-release.apk',
        'https://github.com/someone-else/de_portfolio/releases/download/v1.3.1/app-release.apk',
      ]) {
        final release = await serviceReplying((_) => http.Response(jsonEncode(releaseJson(apkUrl: url)), 200))
            .latestRelease();
        expect(release, isNull, reason: url);
      }
    });

    test('refuses a release without a checksum to verify against', () async {
      final service = serviceReplying((_) => http.Response(jsonEncode(releaseJson(checksumUrl: null)), 200));
      await expectLater(service.latestRelease(), throwsA(isA<UpdateException>()));
    });

    test('no releases yet means nothing to offer', () async {
      expect(await serviceReplying((_) => http.Response('Not Found', 404)).latestRelease(), isNull);
    });

    test('explains rate limits and network failures', () async {
      await expectLater(
        serviceReplying((_) => http.Response('rate limited', 403)).latestRelease(),
        throwsA(predicate((e) => e.toString().contains('rate-limiting'))),
      );
      final offline = UpdateService(client: MockClient((_) async => throw const SocketException('offline')));
      await expectLater(
        offline.latestRelease(),
        throwsA(predicate((e) => e.toString().contains('Could not reach GitHub'))),
      );
    });
  });

  group('download', () {
    late Directory dir;
    final apkBytes = utf8.encode('pretend this is an APK');
    final goodChecksum = '${sha256.convert(apkBytes)}  app-release.apk\n';

    setUp(() => dir = Directory.systemTemp.createTempSync('update_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    UpdateService serving({required String checksum, List<int>? apk, int? declaredLength}) =>
        UpdateService(client: MockClient.streaming((request, _) async {
          if (request.url.path.endsWith('.sha256')) {
            return http.StreamedResponse(Stream.value(utf8.encode(checksum)), 200);
          }
          final body = apk ?? apkBytes;
          return http.StreamedResponse(Stream.value(body), 200, contentLength: declaredLength ?? body.length);
        }));

    test('saves a verified APK, reports progress and clears old downloads', () async {
      File('${dir.path}/app-release-1.3.0.apk').writeAsStringSync('old update');
      final progress = <(int, int?)>[];

      final file = await serving(checksum: goodChecksum)
          .download(release131(), dir, onProgress: (received, total) => progress.add((received, total)));

      expect(file.path, endsWith('app-release-1.3.1.apk'));
      expect(file.readAsBytesSync(), apkBytes);
      expect(progress.last, (apkBytes.length, apkBytes.length));
      expect(dir.listSync().map((f) => f.uri.pathSegments.last), ['app-release-1.3.1.apk']);
    });

    test('a checksum mismatch discards the download', () async {
      final tampered = utf8.encode('tampered bytes');
      await expectLater(
        serving(checksum: goodChecksum, apk: tampered).download(release131(), dir),
        throwsA(predicate((e) => e.toString().contains('checksum'))),
      );
      expect(dir.listSync(), isEmpty);
    });

    test('a truncated download is discarded', () async {
      await expectLater(
        serving(checksum: goodChecksum, declaredLength: apkBytes.length + 100).download(release131(), dir),
        throwsA(predicate((e) => e.toString().contains('interrupted'))),
      );
      expect(dir.listSync(), isEmpty);
    });

    test('an unreadable checksum stops before downloading anything', () async {
      await expectLater(
        serving(checksum: 'not a hash').download(release131(), dir),
        throwsA(predicate((e) => e.toString().contains('checksum'))),
      );
      expect(dir.existsSync() ? dir.listSync() : [], isEmpty);
    });
  });
}
