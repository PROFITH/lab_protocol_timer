import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lab_protocol_timer/services/lab_redcap_service.dart';
import 'package:lab_protocol_timer/services/redcap_connection.dart';
import 'package:lab_protocol_timer/setup/redcap_settings_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const token = '0123456789ABCDEF0123456789ABCDEF';
  const other = 'FEDCBA9876543210FEDCBA9876543210';
  const run4health = RedcapProject(
    title: 'RUN4HEALTH',
    longitudinal: true,
    events: {
      'da_0__visita_inici_arm_1': 'Día 0 (visita inicial)',
      'da_8__visita_final_arm_1': 'Día 8 (visita final)',
    },
  );

  /// REDCap answering the project and event exports.
  MockClient redcap({
    String title = 'RUN4HEALTH',
    bool longitudinal = true,
    List<Map<String, dynamic>>? events,
    String accepted = token,
    List<Map<String, String>>? requests,
  }) =>
      MockClient((request) async {
        final body = Uri.splitQueryString(request.body);
        requests?.add(body);
        if (body['token'] != accepted) {
          return http.Response(jsonEncode({'error': 'You do not have permissions to use the API'}), 403);
        }
        switch (body['content']) {
          case 'project':
            return http.Response(
                jsonEncode({'project_title': title, 'is_longitudinal': longitudinal ? 1 : 0}), 200,
                headers: {'content-type': 'application/json; charset=utf-8'});
          case 'event':
            return http.Response(
                jsonEncode(events ??
                    [
                      {'unique_event_name': 'da_0__visita_inici_arm_1', 'event_name': 'Día 0 (visita inicial)', 'arm_num': 1},
                      {'unique_event_name': 'da_8__visita_final_arm_1', 'event_name': 'Día 8 (visita final)', 'arm_num': 1},
                    ]),
                200,
                headers: {'content-type': 'application/json; charset=utf-8'});
        }
        return http.Response('{"error":"?"}', 400);
      });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    RedcapConnection.use();
  });

  test('addresses and tokens are checked before they are used', () {
    expect(RedcapConnection.normalizeUrl(''), RedcapConnection.defaultUrl);
    expect(RedcapConnection.normalizeUrl(' https://redcap.example.org/api '), 'https://redcap.example.org/api/');
    expect(RedcapConnection.normalizeUrl('https://redcap.example.org/api/'), 'https://redcap.example.org/api/');
    expect(RedcapConnection.normalizeUrl('redcap.ugr.es'), isNull);
    expect(RedcapConnection.normalizeUrl('ftp://redcap.ugr.es/api/'), isNull);
    expect(RedcapConnection.isValidToken(token), isTrue);
    expect(RedcapConnection.isValidToken(token.toLowerCase()), isTrue);
    expect(RedcapConnection.isValidToken('${token}0'), isFalse);
    expect(RedcapConnection.isValidToken('XYZ'), isFalse);
    expect(RedcapConnection.masked(token), '••••••••CDEF');
  });

  test('REDCap tells the project and its visits, with the arm when there are several', () async {
    final one = await RedcapConnection.check(url: RedcapConnection.defaultUrl, token: token, client: redcap());
    expect(one.title, 'RUN4HEALTH');
    expect(one.longitudinal, isTrue);
    expect(one.events, run4health.events);

    final arms = await RedcapConnection.check(
      url: RedcapConnection.defaultUrl,
      token: token,
      client: redcap(events: [
        {'unique_event_name': 'baseline_arm_1', 'event_name': 'Baseline', 'arm_num': 1},
        {'unique_event_name': 'baseline_arm_2', 'event_name': 'Baseline', 'arm_num': 2},
      ]),
    );
    expect(arms.events, {'baseline_arm_1': 'Baseline (brazo 1)', 'baseline_arm_2': 'Baseline (brazo 2)'});

    final requests = <Map<String, String>>[];
    final classic = await RedcapConnection.check(
      url: RedcapConnection.defaultUrl,
      token: token,
      client: redcap(title: 'Otro estudio', longitudinal: false, requests: requests),
    );
    expect(classic.longitudinal, isFalse);
    expect(classic.events, isEmpty);
    expect(requests.map((r) => r['content']), ['project'], reason: 'a classic project has no events to ask');
  });

  test('a token REDCap refuses, or an address without the API, is explained', () async {
    await expectLater(
      RedcapConnection.check(url: RedcapConnection.defaultUrl, token: other, client: redcap()),
      throwsA(isA<RedcapCheckError>().having((e) => e.message, 'message', contains('no acepta este token'))),
    );
    final page = MockClient((_) async => http.Response('<html>REDCap</html>', 200));
    await expectLater(
      RedcapConnection.check(url: 'https://redcap.ugr.es/', token: token, client: page),
      throwsA(isA<RedcapCheckError>().having((e) => e.message, 'message', contains('/api/'))),
    );
  });

  test('the connection is kept on this computer, and another token forgets the old project', () async {
    await RedcapConnection.save(url: 'https://redcap.example.org/api/', token: token, project: run4health);
    RedcapConnection.use();
    expect(RedcapConnection.isConfigured, isFalse);

    await RedcapConnection.load();
    expect(RedcapConnection.url, 'https://redcap.example.org/api/');
    expect(RedcapConnection.token, token);
    expect(RedcapConnection.tokenFromApp, isTrue);
    expect(RedcapConnection.project!.title, 'RUN4HEALTH');
    expect(RedcapConnection.events, run4health.events);

    // An empty token keeps the one in use (and its project).
    await RedcapConnection.save(url: 'https://redcap.example.org/api/');
    expect(RedcapConnection.token, token);
    expect(RedcapConnection.events, run4health.events);

    await RedcapConnection.save(url: 'https://redcap.example.org/api/', token: other);
    expect(RedcapConnection.token, other);
    expect(RedcapConnection.project, isNull);

    await RedcapConnection.forgetToken();
    expect(RedcapConnection.isConfigured, isFalse);
    await RedcapConnection.load();
    expect(RedcapConnection.isConfigured, isFalse);
    expect(RedcapConnection.url, 'https://redcap.example.org/api/');
  });

  test('the visits are asked again in the background and kept without network', () async {
    RedcapConnection.use(token: token);
    await RedcapConnection.refreshProject(client: redcap());
    expect(RedcapConnection.events, run4health.events);

    final offline = MockClient((_) async => throw const SocketExceptionLike());
    await RedcapConnection.refreshProject(client: offline);
    expect(RedcapConnection.events, run4health.events);
  });

  test('a project without events gets the records without redcap_event_name', () async {
    final records = [
      {'record_id': '001', 'redcap_event_name': 'da_0__visita_inici_arm_1', 'ws_session_id': 'x'},
      {'record_id': '002', 'redcap_event_name': '', 'ws_session_id': 'y'},
    ];
    final longitudinal = LabRedCapService.forProject(records, withoutEvents: false);
    expect(longitudinal[0]['redcap_event_name'], 'da_0__visita_inici_arm_1');
    expect(longitudinal[1].containsKey('redcap_event_name'), isFalse);
    final classic = LabRedCapService.forProject(records, withoutEvents: true);
    expect(classic.every((r) => !r.containsKey('redcap_event_name')), isTrue);
    expect(records[0]['redcap_event_name'], 'da_0__visita_inici_arm_1', reason: 'the session keeps its records');

    RedcapConnection.use(token: token, project: const RedcapProject(title: 'Otro', longitudinal: false));
    expect(RedcapConnection.withoutEvents, isTrue);
    RedcapConnection.use(token: token);
    expect(RedcapConnection.withoutEvents, isFalse, reason: 'not known yet: the event goes');
  });

  test('without a token nothing is sent', () async {
    expect(LabRedCapService.isConfigured, isFalse);
    final error = await LabRedCapService.importRecords([
      {'record_id': '001'},
    ]);
    expect(error, contains('Conexión con REDCap'));
  });

  Future<void> openDialog(WidgetTester tester, http.Client client) async {
    tester.view.physicalSize = const Size(1400, 1100);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showRedcapSettingsDialog(context, client: client),
          child: const Text('abrir'),
        ),
      ),
    ));
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
  }

  testWidgets('the token is tried and saved in the app', (tester) async {
    await openDialog(tester, redcap());
    expect(find.textContaining('Ahora no hay token'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('redcap_token')), 'abc');
    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();
    expect(find.textContaining('32 letras'), findsWidgets);
    expect(RedcapConnection.isConfigured, isFalse);

    await tester.enterText(find.byKey(const ValueKey('redcap_token')), token);
    await tester.tap(find.text('Probar conexión'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Conectado con «RUN4HEALTH»'), findsOneWidget);
    expect(find.textContaining('Día 8 (visita final)'), findsOneWidget);

    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();
    expect(find.text('Conexión con REDCap'), findsNothing);
    expect(RedcapConnection.token, token);
    expect(RedcapConnection.events, run4health.events);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(RedcapConnection.tokenKey), token);
  });

  testWidgets('a refused token is shown, and the token can be removed', (tester) async {
    RedcapConnection.use(token: token, project: run4health);
    await openDialog(tester, redcap(accepted: other));
    expect(find.textContaining('••••••••CDEF'), findsOneWidget);

    await tester.tap(find.text('Probar conexión'));
    await tester.pumpAndSettle();
    expect(find.textContaining('no acepta este token'), findsOneWidget);

    await tester.tap(find.text('Quitar token'));
    await tester.pumpAndSettle();
    expect(RedcapConnection.isConfigured, isFalse);
    expect(RedcapConnection.events, isEmpty);
  });
}

/// A network error, as the client throws it without connection.
class SocketExceptionLike implements Exception {
  const SocketExceptionLike();
}
