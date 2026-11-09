import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lab_protocol_timer/models/activity_battery.dart';
import 'package:lab_protocol_timer/models/device_configuration.dart';
import 'package:lab_protocol_timer/models/protocol_configuration.dart';
import 'package:lab_protocol_timer/windows/window_messages.dart';
import 'package:lab_protocol_timer/session/session_controller.dart';
import 'package:lab_protocol_timer/setup/participant_setup_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory root;

  setUp(() {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.platformDispatcher.views.first.physicalSize = const Size(1400, 2400);
    binding.platformDispatcher.views.first.devicePixelRatio = 1.0;
    root = Directory.systemTemp.createTempSync('lpt_setup_');
  });

  tearDown(() => root.deleteSync(recursive: true));

  Future<void> wait(WidgetTester tester, bool Function() done) async {
    // Real time for the asset bundle (an isolate for the big files) and prefs.
    for (var i = 0; i < 200 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  FilledButton startButton(WidgetTester tester) => tester.widget<FilledButton>(find.ancestor(
        of: find.textContaining('PREPARAR SESIÓN'),
        matching: find.byWidgetPredicate((w) => w is FilledButton),
      ));

  Future<SessionController?> startSession(
    WidgetTester tester,
    String id, {
    SyncKind? choose,
    String? h10Serial,
    bool calibratedToday = false,
    List<String>? operators,
    List<String>? expectOperatorFields,
  }) async {
    SessionController? started;
    var monitorOpened = 0;
    final monitor = _FakeLiveMonitor();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: ParticipantSetupPage(
        onStart: (controller) async => started = controller,
        onPrepare: (configuration, fresh) async {
          monitorOpened++;
          monitor.configuration = configuration;
        },
        monitor: monitor,
        audioFactory: SilentAudio.new,
        checkUnfinished: false,
      ),
    ));
    await wait(tester, () => find.textContaining('RUN4HEALTH (base)').evaluate().isNotEmpty);

    // Without an ID the protocol and the folders wait, and nothing starts.
    expect(find.byKey(const ValueKey('setup_section_2_hint')), findsOneWidget);
    expect(find.byKey(const ValueKey('setup_section_3_hint')), findsOneWidget);
    expect(startButton(tester).onPressed, isNull);

    await tester.enterText(find.byType(TextFormField).first, id);
    await tester.pump();
    expect(find.byKey(const ValueKey('setup_section_2_hint')), findsNothing);
    expect(find.byKey(const ValueKey('setup_section_3_hint')), findsNothing);
    expect(startButton(tester).onPressed, isNotNull);
    // Serials and calibration wait for the waiting room.
    expect(find.text('SENSORES DE $id'), findsNothing);
    expect(find.byKey(const Key('calibrate')), findsNothing);
    expect(find.textContaining('R4H_$id${Platform.pathSeparator}D0'), findsOneWidget);

    if (expectOperatorFields != null) {
      for (var i = 0; i < expectOperatorFields.length; i++) {
        final field = tester.widget<TextFormField>(find.byKey(ValueKey('operator_field_$i')));
        expect(field.controller!.text, expectOperatorFields[i], reason: 'evaluador ${i + 1}');
      }
      expect(find.byKey(ValueKey('operator_field_${expectOperatorFields.length}')), findsNothing);
    }
    if (operators != null) {
      for (var i = 0; i < operators.length; i++) {
        if (find.byKey(ValueKey('operator_field_$i')).evaluate().isEmpty) {
          await tester.ensureVisible(find.byKey(const ValueKey('add_operator')));
          await tester.tap(find.byKey(const ValueKey('add_operator')));
          await tester.pump();
        }
        final field = find.byKey(ValueKey('operator_field_$i'));
        await tester.ensureVisible(field);
        await tester.enterText(field, operators[i]);
        await tester.pump();
      }
    }
    if (choose != null) {
      await tester.tap(find.byKey(ValueKey('sync_kind_${choose.name}')));
      await tester.pump();
    }

    // The waiting room: the monitor opens to connect the Polar and camera.
    await tester.ensureVisible(find.byKey(const Key('prepare_session')));
    await tester.tap(find.byKey(const Key('prepare_session')));
    await wait(tester, () => monitorOpened > 0);
    expect(find.byKey(const Key('waiting_room')), findsOneWidget);
    expect(find.byKey(const Key('calibrate')), findsOneWidget);
    expect(find.text('SENSORES DE $id'), findsOneWidget);
    // Day 0: the protocol's free-living set (Matrix, SENS and both AX6)
    // asks for the serial of the device the participant takes home.
    expect(find.widgetWithText(TextFormField, 'Vida libre'), findsNWidgets(4));

    if (h10Serial != null) {
      final field = find.widgetWithText(TextFormField, 'Polar H10 · Pecho');
      await tester.ensureVisible(field);
      await tester.enterText(field, h10Serial);
      await tester.pump();
    }
    // The evaluator ticks each device once initialized and links the Polar
    // here (the monitor keeps the link).
    await wait(tester, () => find.text('Sin conectar').evaluate().length == 2);
    final checks = find.byType(Checkbox);
    expect(checks, findsNWidgets(12));
    expect(find.textContaining('0/14 listos'), findsOneWidget);
    for (var i = 0; i < checks.evaluate().length; i++) {
      await tester.ensureVisible(checks.at(i));
      await tester.tap(checks.at(i));
      await tester.pump();
    }
    expect(find.textContaining('12/14 listos'), findsOneWidget);
    for (var i = 0; i < 2; i++) {
      final connect = find.widgetWithText(TextButton, 'Conectar').first;
      await tester.ensureVisible(connect);
      await tester.tap(connect);
      await wait(tester, () => find.text('Vincular').evaluate().isNotEmpty);
      await tester.tap(find.text('Vincular').first);
      await wait(tester, () => find.text('Vincular').evaluate().isEmpty);
    }
    await wait(tester, () => find.textContaining('14/14 listos').evaluate().isNotEmpty);
    expect(find.textContaining('Conectado · Polar'), findsNWidgets(2));
    expect(monitor.linked.length, 2);

    // The «i» opens the initialization guide of the device.
    await tester.ensureVisible(find.byIcon(Icons.info_outline_rounded).first);
    await tester.tap(find.byIcon(Icons.info_outline_rounded).first);
    await wait(tester, () => find.text('Cerrar').evaluate().isNotEmpty);
    expect(find.textContaining(RegExp('inicializar|preparar'), findRichText: true), findsWidgets);
    await tester.tap(find.text('Cerrar'));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('go_to_session')));
    await tester.tap(find.byKey(const Key('go_to_session')));
    // Sensors without a calibration of today (here they have no serial
    // numbers to match): the technician is asked first.
    await wait(tester, () => find.text('Sensores sin calibrar').evaluate().isNotEmpty);
    expect(
      find.textContaining(calibratedToday ? 'Sin calibración de hoy:' : 'No hay ninguna calibración de hoy'),
      findsOneWidget,
    );
    await tester.tap(find.text('Empezar sin calibrar'));
    await wait(tester, () => find.text('Faltan números de serie').evaluate().isNotEmpty);
    expect(find.text('Sensores sin calibrar'), findsNothing);
    await tester.tap(find.text('Empezar').last);
    await wait(tester, () => started != null);
    // What was ticked reaches the session and the monitor (green dot).
    final offline = started!.participants.single.sensors.where((x) => x.connection == 'offline');
    expect(offline.where((x) => x.inLab).every((x) => x.initialized), isTrue);
    expect(offline.where((x) => x.inFreeLiving).every((x) => x.freeLivingInitialized), isTrue);
    final devices = started!.protocolConfiguration.devices.where((d) => d.connection == 'offline');
    expect(devices, isNotEmpty);
    expect(devices.every((d) => d.initialized), isTrue);
    expect(DeviceConfiguration.fromJson(devices.first.toJson()).initialized, isTrue);
    return started;
  }

  // One test: the asset bundle does not reload the base protocols in a
  // second widget test of the same file.
  testWidgets('clap or jump is chosen once per computer and reaches every session',
      (tester) async {
    // The only evaluator remembered by 1.3.x fills the first of two fields.
    SharedPreferences.setMockInitialValues({'lpt_data_root': root.path, 'lpt_operator': 'OLD'});

    // Nothing chosen yet: the protocol's own clap. The serial typed for the
    // participant goes with their sensors. Three evaluators (a third field
    // added).
    final first = await startSession(
      tester,
      'P01',
      h10Serial: 'C0FFEE',
      expectOperatorFields: ['OLD', ''],
      operators: ['JHM', ' MDF ', 'SPR'],
    );
    expect(first!.operators, ['JHM', 'MDF', 'SPR']);
    expect(first.operator, 'JHM, MDF, SPR');
    expect(first.battery!.sync.kind, SyncKind.clap);
    final worn = first.participants.single.sensors;
    expect(worn.map((s) => s.sensorId), isNot(contains('cam_room')));
    expect(worn.firstWhere((s) => s.sensorId == 'polar_h10').serial, 'C0FFEE');
    expect(worn.firstWhere((s) => s.sensorId == 'ax3_wnd').serial, isNull);
    expect(first.participants.single.folder, isNull);
    expect(first.calibrations, isEmpty);
    first.dispose();

    // A calibration done this morning goes with the session.
    final calib = Directory('${root.path}${Platform.pathSeparator}calibraciones')..createSync();
    final t0 = DateTime.now().subtract(const Duration(minutes: 30)).toUtc();
    final t1 = t0.add(const Duration(minutes: 10));
    File('${calib.path}${Platform.pathSeparator}calibracion_test.csv').writeAsStringSync(
      'event,face,time_utc,time_local,detail\n'
      'calibration_start,,${t0.toIso8601String()},,\n'
      'device,,${t0.toIso8601String()},,ax6:A1\n'
      'face_start,1,${t0.toIso8601String()},,\n'
      'calibration_end,,${t1.toIso8601String()},,\n',
    );

    // Jump chosen: it goes to the session and is kept on this computer.
    final second = await startSession(
      tester,
      'P02',
      choose: SyncKind.jump,
      calibratedToday: true,
      // The evaluators of the last session come back.
      expectOperatorFields: ['JHM', 'MDF', 'SPR'],
    );
    expect(second!.operators, ['JHM', 'MDF', 'SPR']);
    expect(second.calibrations.single.end, t1);
    expect(second.calibrations.single.devices.single.serial, 'A1');
    expect(second.battery!.sync.kind, SyncKind.jump);
    expect(second.battery!.sync.auto, AutoSync.everyStatic);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('lpt_sync_kind'), 'jump');
    expect(prefs.getStringList('lpt_operators'), ['JHM', 'MDF', 'SPR']);
    expect(prefs.getString('lpt_operator'), isNull);
    second.dispose();

    // Next participants, new or returning: jump again without touching it,
    // and the protocol is not marked as modified. A returning participant
    // gets their serials back.
    for (final id in ['P03', 'P02', 'P01']) {
      final next = await startSession(tester, id, calibratedToday: true);
      expect(next!.battery!.sync.kind, SyncKind.jump, reason: id);
      // (P01 comes back with a serial, which counts as an edited protocol.)
      if (id != 'P01') expect(find.textContaining('(modificado)'), findsNothing, reason: id);
      final h10 = next.participants.single.sensors.firstWhere((s) => s.sensorId == 'polar_h10');
      expect(h10.serial, id == 'P01' ? 'C0FFEE' : isNull, reason: id);
      next.dispose();
    }
    await tester.pumpWidget(const SizedBox());
  });
}

/// The Research Monitor as the waiting room sees it: the Polar of the
/// protocol, a unit found for each and linking.
class _FakeLiveMonitor implements MonitorLink {
  ProtocolConfiguration? configuration;
  final Map<String, String> linked = {};

  @override
  Future<dynamic> send(String method, [dynamic arguments]) async {
    final args = arguments is Map ? arguments : const {};
    final live = [
      for (final d in configuration?.devices ?? const <DeviceConfiguration>[])
        if (d.isLive) d,
    ];
    switch (method) {
      case WindowMessages.liveDevices:
        return [
          for (final d in live)
            {
              'device_id': d.deviceId,
              'sensor_id': d.sensorId,
              'participant_id': d.participantId,
              'state': linked.containsKey(d.deviceId) ? 'connected' : 'disconnected',
              'message': '',
              'name': linked[d.deviceId],
              'hr': linked.containsKey(d.deviceId) ? 70 : 0,
            },
        ];
      case WindowMessages.liveScan:
        return [
          {'id': 'BLE-${args['device_id']}', 'name': 'Polar ${args['device_id']}', 'match': 1},
        ];
      case WindowMessages.liveConnect:
        final id = args['device_id'].toString();
        linked[id] = 'Polar $id';
        return {'ok': true, 'message': 'Conectado a Polar $id'};
    }
    return null;
  }
}
