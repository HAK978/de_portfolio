/// A short-lived login challenge created by the backend.
class SteamLoginSession {
  final String sessionId;
  final Uri loginUrl;
  final Uri returnTo;

  SteamLoginSession(Map<String, dynamic> data)
      : sessionId = data['sessionId'] as String,
        loginUrl = Uri.parse(data['loginUrl'] as String),
        returnTo = Uri.parse(data['returnTo'] as String);

  bool isCallback(Uri uri) =>
      uri.scheme == returnTo.scheme &&
      uri.host == returnTo.host &&
      uri.port == returnTo.port &&
      uri.path == returnTo.path;

  Map<String, String> assertionFrom(Uri uri) {
    if (!isCallback(uri) || uri.queryParameters['state'] != sessionId ||
        uri.queryParametersAll.values.any((values) => values.length != 1) ||
        uri.queryParameters['openid.return_to'] != returnTo.toString()) {
      throw const FormatException('Steam returned an invalid login response.');
    }
    return Map.fromEntries(uri.queryParameters.entries.where(
      (entry) => entry.key.startsWith('openid.'),
    ));
  }
}
