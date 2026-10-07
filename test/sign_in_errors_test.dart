// The sign-in screen used to answer every failure with "check your
// connection", which hid a server-side App Check rejection. Each kind of
// failure now gets its own message.

import 'package:cloud_functions/cloud_functions.dart';
import 'package:de_portfolio/services/sign_in_errors.dart';
import 'package:flutter_test/flutter_test.dart';

FirebaseFunctionsException failure(String code) =>
    FirebaseFunctionsException(message: 'server said no', code: code);

void main() {
  test('an App Check rejection says the install couldn\'t be verified, not "check your connection"', () {
    for (final code in ['unauthenticated', 'permission-denied', 'failed-precondition']) {
      final message = signInStartErrorMessage(failure(code));
      expect(message, contains('couldn\'t verify this install'), reason: code);
      expect(message, isNot(contains('connection')), reason: code);
    }
  });

  test('network trouble does say to check the connection', () {
    for (final code in ['unavailable', 'deadline-exceeded']) {
      expect(signInStartErrorMessage(failure(code)), contains('Check your connection'), reason: code);
    }
  });

  test('anything else gets a generic retry message', () {
    expect(signInStartErrorMessage(failure('internal')), contains('Try again'));
    expect(signInStartErrorMessage(StateError('boom')), contains('Try again'));
    expect(signInStartErrorMessage(const FormatException('bad data')), contains('Try again'));
  });
}
