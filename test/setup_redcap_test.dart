import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lab_protocol_timer/services/redcap_connection.dart';
import 'package:lab_protocol_timer/session/session_controller.dart';
import 'package:lab_protocol_timer/setup/participant_setup_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory root;

  setUp(() {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.platformDispatcher.views.first.physicalSize = const Size(1400, 2400);
    binding.platformDispatcher.views.first.devicePixelRatio = 1.0;
    root = Directory.systemTemp.createTempSync('lpt_setup_redcap_');
  });

  tearDown(() {
    RedcapConnection.use();
    root.deleteSync(recursive: true);
  });

  Future<void> wait(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  // One test: the asset bundle does not reload the base protocols in a
  // second widget test of the same file.
  testWidgets('the visits come from the REDCap project, and without REDCap the session still starts',
      (tester) async {
    SharedPreferences.setMockInitialValues({'lpt_data_root': root.path});
    RedcapConnection.use(
      token: '0123456789ABCDEF0123456789ABCDEF',
      project: const RedcapProject(
        title: 'Otro estudio',
        longitudinal: true,
        events: {'baseline_arm_1': 'Baseline', 'followup_arm_1': 'Seguimiento'},
      ),
    );

    SessionController? started;
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
    expect(find.textContaining('Proyecto «Otro estudio»'), findsOneWidget);
    expect(find.text('Baseline'), findsOneWidget);
    expect(find.text('Visita Inicial (Día 0)'), findsNothing);

    await tester.enterText(find.byType(TextFormField).first, 'P01');
    await tester.tap(find.textContaining('COMENZAR SESIÓN'));
    await wait(tester, () => find.text('Faltan números de serie').evaluate().isNotEmpty);
    await tester.tap(find.text('Empezar').last);
    await wait(tester, () => started != null);
    expect(started!.participants.single.redcapEventName, 'baseline_arm_1');
    expect(started!.redcapConfigured, isTrue);
    started!.dispose();
    started = null;

    // The token is removed: RUN4HEALTH's visits again, and the session goes
    // on without REDCap.
    RedcapConnection.use();
    await tester.pump();
    expect(find.textContaining('Sin conexión: cada sesión se guarda solo en su carpeta'), findsOneWidget);
    expect(find.text('Conectar'), findsOneWidget);
    expect(find.text('Visita Inicial (Día 0)'), findsOneWidget);
    expect(find.text('Baseline'), findsNothing);

    await tester.tap(find.textContaining('COMENZAR SESIÓN'));
    await wait(tester, () => find.text('Faltan números de serie').evaluate().isNotEmpty);
    await tester.tap(find.text('Empezar').last);
    await wait(tester, () => started != null);
    expect(started!.participants.single.redcapEventName, 'da_0__visita_inici_arm_1');
    expect(started!.redcapConfigured, isFalse);
    expect(started!.info()['redcap_configured'], isFalse);
    started!.dispose();
  });
}
