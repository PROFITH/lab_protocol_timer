import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lab_protocol_timer/services/redcap_resend.dart';

void main() {
  const d0 = 'da_0__visita_inici_arm_1';
  final records = <Map<String, dynamic>>[
    {'record_id': '001', 'redcap_event_name': d0, 'lab_total_stations': '9'},
    {'record_id': '002', 'redcap_event_name': d0, 'lab_total_stations': '9'},
    {'record_id': '001', 'redcap_event_name': d0, 'ws_session_id': 'R4H_001_D0'},
    {'record_id': '001', 'redcap_event_name': d0, 'redcap_repeat_instrument': 'lab_activity',
      'redcap_repeat_instance': 1, 'la_rpe': '3'},
    {'record_id': '001', 'redcap_event_name': d0, 'redcap_repeat_instrument': 'lab_activity',
      'redcap_repeat_instance': 2, 'la_rpe': '5'},
    {'record_id': '001', 'redcap_event_name': d0, 'fit_chair_reps': '14'},
  ];

  late Directory folder;

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('lpt_resend_');
  });

  tearDown(() async {
    if (await folder.exists()) await folder.delete(recursive: true);
  });

  test('the records split into imports REDCap takes: repeating apart, one row per record and event', () {
    final imports = SavedSessionRedcap.importsFromRecords(records);
    expect(imports.map((b) => b.length).toList(), [2, 1, 1, 2]);
    expect(imports.last.every((r) => r['redcap_repeat_instrument'] == 'lab_activity'), isTrue);
    for (final batch in imports.take(3)) {
      final keys = batch.map((r) => '${r['record_id']}|${r['redcap_event_name']}').toList();
      expect(keys.toSet().length, keys.length);
    }
    expect(imports.expand((b) => b).length, records.length);
  });

  test('a saved session is sent from its folder and then marked as sent', () async {
    File('${folder.path}/redcap_records.json').writeAsStringSync(jsonEncode(records));
    final sent = <List<Map<String, dynamic>>>[];
    final error = await SavedSessionRedcap.send(
      folder,
      importRecords: (batch) async {
        sent.add(batch);
        return null;
      },
      now: DateTime(2026, 10, 21, 10, 5, 9),
    );
    expect(error, isNull);
    expect(sent.length, 4);
    expect(File('${folder.path}/redcap_records.json').existsSync(), isFalse);
    expect(File('${folder.path}/redcap_records_enviados_20261021_100509.json').existsSync(), isTrue);

    // Nothing left to send.
    final again = await SavedSessionRedcap.send(folder, importRecords: (_) async => null);
    expect(again, contains('no hay nada pendiente'));
  });

  test('a form that is not repeating is named, and the records stay pending', () async {
    File('${folder.path}/redcap_records.json').writeAsStringSync(jsonEncode(records));
    final error = await SavedSessionRedcap.send(
      folder,
      importRecords: (batch) async => batch.any((r) => r.containsKey('redcap_repeat_instrument'))
          ? 'REDCap respondió 400: {"error":"lab_activity is not a repeating instrument"}'
          : null,
    );
    expect(error, startsWith('Envío 4 de 4: '));
    expect(error, contains('«lab_activity» tiene que ser un instrumento repetible en $d0'));
    expect(error, contains('«Enviar a REDCap una sesión guardada»'));
    expect(File('${folder.path}/redcap_records.json').existsSync(), isTrue);
  });

  test('an unreadable file is reported, not sent', () async {
    File('${folder.path}/redcap_records.json').writeAsStringSync('{roto');
    var calls = 0;
    final error = await SavedSessionRedcap.send(folder, importRecords: (_) async {
      calls++;
      return null;
    });
    expect(error, startsWith('No se pudo leer redcap_records.json'));
    expect(calls, 0);
  });
}
