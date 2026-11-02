import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lab_protocol_timer/services/phone_records_import.dart';

const d8 = 'da_8__visita_final_arm_1';
const url = 'https://minerva.ugr.es/api/';

/// Test token with the shape of REDCap's (not a real one).
const token = '0123456789ABCDEF0123456789ABCDEF';

/// A REDCap project in memory: its records and the rows of the repeating
/// `healthy_tracker` instrument, answering the API calls the import makes.
class FakeRedcap {
  final records = <String>{'R4H_001'};
  final rows = <Map<String, dynamic>>[];
  final uploads = <String, ({String name, List<int> bytes})>{};
  final calls = <Map<String, String>>[];
  String? rejectImport;

  late final MockClient client = MockClient((request) async {
    if (request.headers['content-type']?.startsWith('multipart/form-data') == true) return _file(request);
    final body = request.bodyFields;
    calls.add(body);
    expect(body['token'], token);
    if (body['content'] != 'record') return http.Response('{"error":"?"}', 400);
    return body.containsKey('data') ? _import(body) : _export(body);
  });

  void add(Map<String, dynamic> row) => rows.add({
        'record_id': 'R4H_001',
        'redcap_event_name': d8,
        'redcap_repeat_instrument': 'healthy_tracker',
        ...row,
      });

  List<Map<String, String>> get imports => [for (final c in calls) if (c.containsKey('data')) c];

  http.Response _export(Map<String, String> body) {
    final record = body['records[0]'];
    final event = body['events[0]'];
    if (!records.contains(record)) return http.Response('[]', 200);
    final fields = [for (final e in body.entries) if (e.key.startsWith('fields[')) e.value];
    return http.Response(
      jsonEncode([
        {'record_id': record, 'redcap_event_name': event ?? d8, 'redcap_repeat_instrument': '', 'redcap_repeat_instance': ''},
        for (final row in rows)
          if (row['record_id'] == record && (event == null || row['redcap_event_name'] == event))
            {
              'record_id': row['record_id'],
              'redcap_event_name': row['redcap_event_name'],
              'redcap_repeat_instrument': row['redcap_repeat_instrument'],
              'redcap_repeat_instance': '${row['redcap_repeat_instance']}',
              for (final field in fields) field: row[field]?.toString() ?? '',
            },
      ]),
      200,
    );
  }

  http.Response _import(Map<String, String> body) {
    if (rejectImport != null) return http.Response(jsonEncode({'error': rejectImport}), 400);
    final data = [for (final row in jsonDecode(body['data']!) as List) Map<String, dynamic>.from(row as Map)];
    for (final row in data) {
      records.add(row['record_id'].toString());
      final same = rows.where((r) =>
          r['record_id'] == row['record_id'] &&
          r['redcap_event_name'] == row['redcap_event_name'] &&
          '${r['redcap_repeat_instance']}' == '${row['redcap_repeat_instance']}');
      if (same.isEmpty) {
        rows.add(row);
      } else {
        same.first.addAll(row);
      }
    }
    return http.Response(jsonEncode({'count': data.length}), 200);
  }

  /// Multipart file import: the fields and the file, read from the body.
  http.Response _file(http.Request request) {
    final text = latin1.decode(request.bodyBytes);
    final fields = <String, String>{};
    String? fileName;
    List<int>? bytes;
    for (final part in RegExp(r'name="([^"]+)"(?:; filename="([^"]+)")?\r\n(?:[^\r\n]+\r\n)*\r\n(.*?)\r\n--', dotAll: true)
        .allMatches(text)) {
      if (part[2] != null) {
        fileName = part[2];
        bytes = latin1.encode(part[3]!);
      } else {
        fields[part[1]!] = part[3]!;
      }
    }
    expect(fields['token'], token);
    expect(fields['content'], 'file');
    expect(fields['action'], 'import');
    final target = rows.where((r) =>
        r['record_id'] == fields['record'] &&
        (fields['event'] == null || r['redcap_event_name'] == fields['event']) &&
        '${r['redcap_repeat_instance']}' == fields['repeat_instance']);
    if (target.isEmpty) return http.Response('{"error":"The record or instance does not exist"}', 400);
    target.first[fields['field']!] = fileName;
    uploads['${fields['repeat_instance']}|${fields['field']}'] = (name: fileName!, bytes: bytes!);
    return http.Response('', 200);
  }
}

void main() {
  final now = DateTime(2026, 10, 28, 12, 0, 0);
  late Directory folder;
  late FakeRedcap redcap;

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('lpt_phone_');
    redcap = FakeRedcap();
  });

  tearDown(() async {
    if (await folder.exists()) await folder.delete(recursive: true);
  });

  PhoneRecordsImport importer({bool withoutEvents = false}) =>
      PhoneRecordsImport(client: redcap.client, url: url, token: token, withoutEvents: withoutEvents);

  Map<String, dynamic> sleepRow(String onset, String wake) => {
        'record_id': 'R4H_001',
        'redcap_event_name': d8,
        'redcap_repeat_instrument': 'healthy_tracker',
        'entry_type': '3',
        'sleep_type': '1',
        'sleep_onset': onset,
        'sleep_wake': wake,
        'sleep_quality': '4',
        'healthy_tracker_complete': '2',
      };

  final meal = {
    'record_id': 'R4H_001',
    'redcap_event_name': d8,
    'redcap_repeat_instrument': 'healthy_tracker',
    'entry_type': '4',
    'meal_time': '2026-10-27 14:05:00',
    'meal_time_end': '2026-10-27 14:30:00',
    'meal_total_kcal': '107.0',
    'healthy_tracker_complete': '2',
  };

  final prompt = {
    'record_id': 'R4H_001',
    'redcap_event_name': d8,
    'redcap_repeat_instrument': 'healthy_tracker',
    'entry_type': '5',
    'ema_type': '3',
    'ema_scheduled': '2026-10-27 20:00:00',
    'ema_status': '1',
    'ema_exercise_done': '0',
    'healthy_tracker_complete': '2',
  };

  /// A file like the phone writes (healthy_tracker's docs/export_format.md).
  File phoneFile(
    String name,
    List<Map<String, dynamic>> rows, {
    List<Map<String, dynamic>> files = const [],
    List<Map<String, dynamic>> skipped = const [],
    String subfolder = 'R4H_001',
  }) {
    final dir = Directory('${folder.path}/$subfolder')..createSync(recursive: true);
    return File('${dir.path}/$name')
      ..writeAsStringSync(jsonEncode({
        'format': 'healthy_tracker_export',
        'version': 1,
        'participant_id': 'R4H_001',
        'created': '2026-10-28T10:15:03.000+01:00',
        'instrument': 'healthy_tracker',
        'type_field': 'entry_type',
        'match_fields': PhoneRecordsImport.defaultMatchFields,
        'counts': {'sleeping': 1},
        'rows': rows,
        'files': files,
        'missing_files': const [],
        'skipped_files': skipped,
      }));
  }

  Map<String, dynamic> photo(int row, List<int> bytes) =>
      {'row': row, 'field': 'meal_photo', 'name': 'comida_20261027_140500.jpg', 'size': bytes.length, 'data': base64.encode(bytes)};

  test('new rows take the next instances, the photo goes to its row and the file is marked as sent', () async {
    redcap.add({'redcap_repeat_instance': 1, 'entry_type': '3', 'sleep_onset': '2026-10-24 23:00:00', 'sleep_wake': '2026-10-25 07:00:00'});
    redcap.add({'redcap_repeat_instance': 2, 'entry_type': '2', 'act_start': '2026-10-25 18:00:00', 'act_end': '2026-10-25 19:00:00', 'act_code': '12020'});
    final file = phoneFile(
      'healthy_tracker_R4H_001_20261028_101503.json',
      [sleepRow('2026-10-26 23:30:00', '2026-10-27 07:15:00'), meal, prompt],
      files: [photo(1, [1, 2, 3, 250])],
    );

    final result = await importer().sendFile(file, now: now);
    expect(result.error, isNull);
    expect(result.imported, 3);
    expect(result.alreadyInRedcap, 0);
    expect(result.filesUploaded, 1);
    expect(redcap.rows.map((r) => '${r['redcap_repeat_instance']}:${r['entry_type']}'), ['1:3', '2:2', '3:3', '4:4', '5:5']);
    expect(redcap.uploads['4|meal_photo']?.name, 'meal_R4H_001_inst4.jpg');
    expect(redcap.uploads['4|meal_photo']?.bytes, [1, 2, 3, 250]);

    expect(file.existsSync(), isFalse);
    expect(result.sentAs, endsWith('healthy_tracker_R4H_001_20261028_101503_enviado_20261028_120000.json'));
    expect(File(result.sentAs!).existsSync(), isTrue);
  });

  test('rows REDCap already has, to the minute, are not sent again; photos only where they are missing', () async {
    // Sent before by ⟳ from the phone, with the photo.
    redcap.add({'redcap_repeat_instance': 1, ...sleepRow('2026-10-26 23:30', '2026-10-27 07:15')});
    redcap.add({'redcap_repeat_instance': 2, ...meal, 'meal_photo': 'meal_R4H_001_inst2.jpg'});
    final file = phoneFile(
      'healthy_tracker_R4H_001_20261028_101503.json',
      [sleepRow('2026-10-26 23:30:00', '2026-10-27 07:15:00'), meal, prompt],
      files: [photo(1, [9, 9])],
    );

    final result = await importer().sendFile(file, now: now);
    expect(result.error, isNull);
    expect(result.imported, 1);
    expect(result.alreadyInRedcap, 2);
    expect(result.filesUploaded, 0);
    expect(result.filesAlreadyInRedcap, 1);
    expect(redcap.rows, hasLength(3));
    expect(redcap.rows.last['redcap_repeat_instance'], 3);
    expect(redcap.uploads, isEmpty);

    // The same rows in another file (the export by cable): nothing new.
    final again = phoneFile(
      'healthy_tracker_R4H_001_20261029_090000.json',
      [sleepRow('2026-10-26 23:30:00', '2026-10-27 07:15:00'), meal, prompt],
    );
    final second = await importer().sendFile(again, now: now);
    expect(second.imported, 0);
    expect(second.alreadyInRedcap, 3);
    expect(redcap.rows, hasLength(3));
    expect(second.sentAs, isNotNull);
  });

  test('a photo too big for Drive arrives later, by cable, at the row already in REDCap', () async {
    final viaDrive = phoneFile(
      'healthy_tracker_R4H_001_20261028_101503.json',
      [meal],
      skipped: [
        {'row': 0, 'field': 'meal_photo', 'path': '/data/user/0/app/files/fotos_comidas/comida.jpg', 'size': 20000000},
      ],
    );
    final first = await importer().sendFile(viaDrive, now: now);
    expect(first.imported, 1);
    expect(first.skippedFiles, 1);
    // The photo field is asked for, to know which rows lack it.
    expect(redcap.calls.where((c) => !c.containsKey('data') && c.containsKey('fields[1]')).last.values, contains('meal_photo'));

    final byCable = phoneFile('healthy_tracker_R4H_001_20261030_180000.json', [meal], files: [photo(0, [7, 7, 7])]);
    final second = await importer().sendFile(byCable, now: now);
    expect(second.imported, 0);
    expect(second.alreadyInRedcap, 1);
    expect(second.filesUploaded, 1);
    expect(redcap.uploads['1|meal_photo']?.bytes, [7, 7, 7]);
  });

  test('two equal rows in one file go once', () async {
    final file = phoneFile('healthy_tracker_R4H_001_20261028_101503.json', [meal, meal], files: [photo(0, [1]), photo(1, [1])]);
    final result = await importer().sendFile(file, now: now);
    expect(result.imported, 1);
    expect(result.alreadyInRedcap, 1);
    expect(result.filesUploaded, 1);
    expect(redcap.rows, hasLength(1));
  });

  test('a participant REDCap does not have: nothing is sent and the file stays', () async {
    redcap.records.clear();
    final file = phoneFile('healthy_tracker_R4H_001_20261028_101503.json', [meal]);

    final result = await importer().sendFile(file, now: now);
    expect(result.error, contains('no existe el participante «R4H_001»'));
    expect(redcap.imports, isEmpty);
    expect(file.existsSync(), isTrue);
  });

  test('when REDCap rejects the rows, the file stays and REDCap\'s answer is shown', () async {
    redcap.rejectImport = 'The following fields were not found in the project as real data fields: meal_total_kcal';
    final file = phoneFile('healthy_tracker_R4H_001_20261028_101503.json', [meal]);

    final result = await importer().sendFile(file, now: now);
    expect(result.error, contains('meal_total_kcal'));
    expect(file.existsSync(), isTrue);

    // Fixed in REDCap: sent, once.
    redcap.rejectImport = null;
    final retried = await importer().sendFile(file, now: now);
    expect(retried.imported, 1);
    expect(redcap.rows, hasLength(1));
  });

  test('in a project without events the rows go without one', () async {
    final file = phoneFile('healthy_tracker_R4H_001_20261028_101503.json', [meal]);
    final result = await importer(withoutEvents: true).sendFile(file, now: now);
    expect(result.error, isNull);
    expect(redcap.calls.any((c) => c.containsKey('events[0]')), isFalse);
    final sent = jsonDecode(redcap.imports.single['data']!) as List;
    expect((sent.single as Map).containsKey('redcap_event_name'), isFalse);
  });

  test('files that are not from the phone, or from a newer app, are not sent', () async {
    final other = File('${folder.path}/healthy_tracker_R4H_001_20261028_101503.json')
      ..writeAsStringSync(jsonEncode({'format': 'otro', 'rows': []}));
    expect((await importer().sendFile(other)).error, contains('No es un archivo de registros de healthy_tracker'));

    final newer = File('${folder.path}/healthy_tracker_R4H_001_20261028_101504.json')
      ..writeAsStringSync(jsonEncode({'format': 'healthy_tracker_export', 'version': 2, 'rows': []}));
    expect((await importer().sendFile(newer)).error, contains('actualiza lab_protocol_timer'));
    expect(redcap.calls, isEmpty);
  });

  test('the folder: phone files in subfolders, by name, without the sent ones', () async {
    phoneFile('healthy_tracker_R4H_002_20261028_090000.json', [meal], subfolder: 'R4H_002');
    phoneFile('healthy_tracker_R4H_001_20261028_101503_2.json', [meal]);
    phoneFile('healthy_tracker_R4H_001_20261028_101503.json', [prompt]);
    phoneFile('healthy_tracker_R4H_001_20261027_090000_enviado_20261027_120000.json', [meal]);
    File('${folder.path}/otro.json').writeAsStringSync('{}');

    final pending = await PhoneRecordsImport.pendingFiles(folder);
    expect(pending.map((f) => PhoneRecordsImport.fileName(f.path)), [
      'healthy_tracker_R4H_001_20261028_101503.json',
      'healthy_tracker_R4H_001_20261028_101503_2.json',
      'healthy_tracker_R4H_002_20261028_090000.json',
    ]);

    redcap.records.add('R4H_002');
    final seen = <String>[];
    final results = await importer().sendFolder(folder, now: now, onFile: (i, n, name) => seen.add('${i + 1}/$n'));
    expect(seen, ['1/3', '2/3', '3/3']);
    expect(results.every((r) => r.sent), isTrue);
    expect(await PhoneRecordsImport.pendingFiles(folder), isEmpty);
  });

  test('the summary says what arrived, what was already there and what is missing', () {
    final summary = PhoneRecordsImport.describe([
      const PhoneFileResult(path: '/d/healthy_tracker_R4H_001_20261028_101503.json', rows: 5, imported: 3, alreadyInRedcap: 2, filesUploaded: 1, skippedFiles: 1),
      const PhoneFileResult(path: '/d/healthy_tracker_R4H_001_20261029_090000.json', rows: 3, alreadyInRedcap: 3),
      const PhoneFileResult(path: '/d/healthy_tracker_R4H_009_20261029_090000.json', error: 'En REDCap no existe el participante «R4H_009»: créalo.'),
    ], '/d');
    expect(summary.title, 'Algunos archivos no se enviaron');
    expect(summary.message, contains('✓ healthy_tracker_R4H_001_20261028_101503.json: 3 registros nuevos y 1 foto o vídeo (otros 2 ya estaban en REDCap).'));
    expect(summary.message, contains('1 foto o vídeo era demasiado grande para Google Drive'));
    expect(summary.message, contains('✓ healthy_tracker_R4H_001_20261029_090000.json: sus 3 registros ya estaban en REDCap.'));
    expect(summary.message, contains('✗ healthy_tracker_R4H_009_20261029_090000.json: En REDCap no existe'));
    expect(summary.message, contains('lo ya enviado no se repite'));

    expect(PhoneRecordsImport.describe(const [], '/d').title, 'Nada que enviar');
  });
}
