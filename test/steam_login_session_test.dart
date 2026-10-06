import 'package:de_portfolio/models/steam_login_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final session = SteamLoginSession({
    'sessionId': 'secret',
    'loginUrl': 'https://steamcommunity.com/openid/login',
    'returnTo': 'https://example.com/return?state=secret',
  });
  final callback = session.returnTo.replace(queryParameters: {
    'state': 'secret',
    'openid.return_to': session.returnTo.toString(),
    'openid.mode': 'id_res',
  });

  test('only forwards OpenID fields from the bound callback', () {
    expect(session.assertionFrom(callback), {
      'openid.return_to': session.returnTo.toString(), 'openid.mode': 'id_res',
    });
  });
  test('rejects wrong scheme, origin, path, state and duplicate parameters', () {
    for (final uri in [
      callback.replace(scheme: 'http'), callback.replace(host: 'evil.example.com'),
      callback.replace(path: '/different'),
      Uri.parse(callback.toString().replaceFirst('state=secret', 'state=other')),
      Uri.parse('$callback&state=secret'),
    ]) {
      expect(() => session.assertionFrom(uri), throwsFormatException);
    }
  });
}
