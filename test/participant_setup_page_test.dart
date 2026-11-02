import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lab_protocol_timer/models/activity_battery.dart';
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
        of: find.textContaining('COMENZAR SESIÓN'),
        matching: find.byWidgetPredicate((w) => w is FilledButton),
      ));

  Future<SessionController?> startSession(
    WidgetTester tester,
    String id, {
    SyncKind? choose,
    String? h10Serial,
  }) async {
    SessionController? started;
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: ParticipantSetupPage(
        onStart: (controller) async => started = controller,
        monitor: NoMonitor(),
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
    expect(find.text('SENSORES DE $id'), findsOneWidget);
    expect(find.textContaining('R4H_$id${Platform.pathSeparator}D0'), findsOneWidget);

    if (choose != null) {
      await tester.tap(find.byKey(ValueKey('sync_kind_${choose.name}')));
      await tester.pump();
    }
    if (h10Serial != null) {
      final field = find.widgetWithText(TextFormField, 'Polar H10 · Pecho');
      await tester.ensureVisible(field);
      await tester.enterText(field, h10Serial);
      await tester.pump();
    }
    await tester.ensureVisible(find.textContaining('COMENZAR SESIÓN'));
    await tester.tap(find.textContaining('COMENZAR SESIÓN'));
    await wait(tester, () => find.text('Faltan números de serie').evaluate().isNotEmpty);
    await tester.tap(find.text('Empezar').last);
    await wait(tester, () => started != null);
    return started;
  }

  // One test: the asset bundle does not reload the base protocols in a
  // second widget test of the same file.
  testWidgets('clap or jump is chosen once per computer and reaches every session',
      (tester) async {
    SharedPreferences.setMockInitialValues({'lpt_data_root': root.path});

    // Nothing chosen yet: the protocol's own clap. The serial typed for the
    // participant goes with their sensors.
    final first = await startSession(tester, 'P01', h10Serial: 'C0FFEE');
    expect(first!.battery!.sync.kind, SyncKind.clap);
    final worn = first.participants.single.sensors;
    expect(worn.map((s) => s.sensorId), isNot(contains('cam_room')));
    expect(worn.firstWhere((s) => s.sensorId == 'polar_h10').serial, 'C0FFEE');
    expect(worn.firstWhere((s) => s.sensorId == 'ax3_wnd').serial, isNull);
    expect(first.participants.single.folder, isNull);
    first.dispose();

    // Jump chosen: it goes to the session and is kept on this computer.
    final second = await startSession(tester, 'P02', choose: SyncKind.jump);
    expect(second!.battery!.sync.kind, SyncKind.jump);
    expect(second.battery!.sync.auto, AutoSync.everyStatic);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('lpt_sync_kind'), 'jump');
    second.dispose();

    // Next participants, new or returning: jump again without touching it,
    // and the protocol is not marked as modified. A returning participant
    // gets their serials back.
    for (final id in ['P03', 'P02', 'P01']) {
      final next = await startSession(tester, id);
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
