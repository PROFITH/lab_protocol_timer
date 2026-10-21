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

  Future<SessionController?> startSession(WidgetTester tester, String id, {SyncKind? choose}) async {
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
    if (choose != null) {
      await tester.tap(find.byKey(ValueKey('sync_kind_${choose.name}')));
      await tester.pump();
    }
    await tester.enterText(find.byType(TextFormField).first, id);
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

    // Nothing chosen yet: the protocol's own clap.
    final first = await startSession(tester, 'P01');
    expect(first!.battery!.sync.kind, SyncKind.clap);
    first.dispose();

    // Jump chosen: it goes to the session and is kept on this computer.
    final second = await startSession(tester, 'P02', choose: SyncKind.jump);
    expect(second!.battery!.sync.kind, SyncKind.jump);
    expect(second.battery!.sync.auto, AutoSync.everyStatic);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('lpt_sync_kind'), 'jump');
    second.dispose();

    // Next participants, new or returning: jump again without touching it,
    // and the protocol is not marked as modified.
    for (final id in ['P03', 'P02']) {
      final next = await startSession(tester, id);
      expect(next!.battery!.sync.kind, SyncKind.jump, reason: id);
      expect(find.textContaining('(modificado)'), findsNothing, reason: id);
      next.dispose();
    }
    await tester.pumpWidget(const SizedBox());
  });
}
