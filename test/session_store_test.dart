import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lab_protocol_timer/services/lab_redcap_service.dart';
import 'package:lab_protocol_timer/session/csv_stream_writer.dart';
import 'package:lab_protocol_timer/session/session_store.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('lpt_store_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  final day0 = [
    ParticipantEntry(participantId: '001', redcapEventName: 'da_0__visita_inici_arm_1'),
  ];
  final day8 = [
    ParticipantEntry(participantId: '001', redcapEventName: 'da_8__visita_final_arm_1'),
  ];

  test('folder names follow the RUN4HEALTH guide', () {
    expect(SessionStore.studyCode('RUN4HEALTH'), 'R4H');
    expect(SessionStore.studyCode('WEARGAP'), 'WG');
    expect(SessionStore.studyCode(null), '');
    expect(SessionStore.visitCode('da_0__visita_inici_arm_1'), 'D0');
    expect(SessionStore.visitCode('da_8__visita_final_arm_1'), 'D8');
    expect(SessionStore.visitCode('otra_visita'), 'otra_visita');
    expect(SessionStore.participantFolder('RUN4HEALTH', day0), 'R4H_001');
    expect(
      SessionStore.participantFolder(null, [
        ParticipantEntry(participantId: 'A/1', redcapEventName: 'x'),
        ParticipantEntry(participantId: 'B 2', redcapEventName: 'x'),
      ]),
      'A_1+B_2',
    );
    expect(SessionStore.safeName('ab:c*?. '), 'ab_c__');
  });

  test('a visit that already has a session gets a new dated folder', () async {
    final root = tmp.path;
    final first = await SessionStore.chooseFolder(
      root: root,
      study: 'RUN4HEALTH',
      participants: day0,
    );
    expect(first.path, endsWith('R4H_001${Platform.pathSeparator}D0'));

    // An empty folder (or one with sensor files only) is reused.
    await first.create(recursive: true);
    await File('${first.path}/ax3.cwa').writeAsString('x');
    expect(
      (await SessionStore.chooseFolder(root: root, study: 'RUN4HEALTH', participants: day0)).path,
      first.path,
    );

    await File('${first.path}/session_state.json').writeAsString('{}');
    final second = await SessionStore.chooseFolder(
      root: root,
      study: 'RUN4HEALTH',
      participants: day0,
      now: DateTime(2026, 10, 21, 9, 5),
    );
    expect(second.path, endsWith('D0_20261021-0905'));
    await second.create();
    await File('${second.path}/session_manifest.json').writeAsString('{}');
    final third = await SessionStore.chooseFolder(
      root: root,
      study: 'RUN4HEALTH',
      participants: day0,
      now: DateTime(2026, 10, 21, 9, 5),
    );
    expect(third.path, endsWith('D0_20261021-0905_2'));

    final d8 = await SessionStore.chooseFolder(root: root, study: 'RUN4HEALTH', participants: day8);
    expect(d8.path, endsWith('R4H_001${Platform.pathSeparator}D8'));
  });

  test('writes are atomic, queued in order and logged events are appended',
      () async {
    final store = await SessionStore.create(Directory('${tmp.path}/s'));
    for (var i = 0; i < 20; i++) {
      store.writeJson('state.json', {'i': i});
    }
    store.logEvent('session_started', activityIndex: 1, attempt: 1, phase: 'static_prep');
    store.logEvent('note', detail: 'con "comillas", y coma');
    await store.close();

    expect(jsonDecode(await File(store.pathOf('state.json')).readAsString()), {'i': 19});
    expect(File('${store.pathOf('state.json')}.tmp').existsSync(), isFalse);
    final lines = await File(store.pathOf(SessionStore.eventsFile)).readAsLines();
    expect(lines.first, SessionStore.eventsHeader);
    expect(lines[1], contains(',session_started,1,1,static_prep,'));
    expect(lines[2], endsWith(',"con ""comillas"", y coma"'));
    expect(store.lastError.value, isNull);

    final state = await SessionStore.readState(store.path);
    expect(state, isNull, reason: 'no session_state.json written');
  });

  test('the CSV writer adds the header once and appends after a restart',
      () async {
    final path = '${tmp.path}/polar_acc.csv';
    final a = CsvStreamWriter(path, 'h1,h2', flushEvery: const Duration(milliseconds: 10));
    a.add('1,2');
    a.add('3,4');
    await a.close();
    final b = CsvStreamWriter(path, 'h1,h2');
    b.add('5,6');
    await b.flush();
    b.add('7,8');
    await b.close();
    expect(await File(path).readAsLines(), ['h1,h2', '1,2', '3,4', '5,6', '7,8']);
    expect(b.rows, 2);
  });

  test('the CSV writer keeps the rows when the folder is missing and retries',
      () async {
    final dir = Directory('${tmp.path}/later');
    final path = '${dir.path}/x.csv';
    final w = CsvStreamWriter(path, 'h', flushEvery: const Duration(milliseconds: 10));
    w.add('1');
    await w.flush();
    expect(w.lastError, isNotNull);
    await dir.create();
    w.add('2');
    await w.close();
    expect(await File(path).readAsLines(), ['h', '1', '2']);
    expect(w.lastError, isNull);
  });

  test('csvField quotes only when needed', () {
    expect(csvField('abc'), 'abc');
    expect(csvField('a,b'), '"a,b"');
    expect(csvField(null), '');
    expect(csvField(3), '3');
  });
}
