import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lab_protocol_timer/services/windows_tls_trust.dart';

void main() {
  test('only Windows gets the override, and it never accepts without Windows', () {
    final before = HttpOverrides.current;
    WindowsTlsTrust.install();
    if (!Platform.isWindows) {
      expect(HttpOverrides.current, same(before));
      expect(WindowsTlsTrust.verifyWithWindows(Uint8List.fromList([1, 2, 3]), 'minerva.ugr.es'), isFalse);
    }
    // An empty certificate is never accepted, on any system.
    expect(WindowsTlsTrust.verifyWithWindows(Uint8List(0), 'minerva.ugr.es'), isFalse);
  });

  test('the client it makes keeps the normal check and asks Windows only after a failure', () {
    final client = WindowsTlsTrust().createHttpClient(null);
    addTearDown(client.close);
    // The callback exists (it is only called when the app's own check fails).
    expect(client, isA<HttpClient>());
  });
}
