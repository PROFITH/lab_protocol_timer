import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lab_protocol_timer/models/activity_battery.dart';
import 'package:lab_protocol_timer/windows/monitor_session.dart';
import 'package:lab_protocol_timer/windows/session_console.dart';

void main() {
  final battery = ActivityBattery.parse(File('assets/protocols/run4health_base.json').readAsStringSync());

  test('after the session the lab sensors are downloaded and the free-living ones restarted', () {
    final after = SensorsAfterSession(battery.sensors);
    expect(after.download.map((s) => s.sensorId), ['ax3_wnd', 'ax3_wd', 'ax3_thigh']);
    expect(after.downloadAndRestart.map((s) => s.sensorId), ['matrix_wnd', 'sens_thigh']);
    expect(after.startFreeLiving.map((s) => s.sensorId), ['verity_arm']);
    expect(after.withoutSerial, hasLength(5));

    final matrix = after.downloadAndRestart.first;
    expect(SensorsAfterSession.fileNameFor(matrix, '/data/R4H_001/D0'), 'R4H_001_D0_matrix_wnd');
    expect(
      SensorsAfterSession.fileNameFor(matrix, r'C:\Users\lab\Documents\lab_protocol_timer_sesiones\R4H_001\D0'),
      'R4H_001_D0_matrix_wnd',
    );
    expect(SensorsAfterSession.fileNameFor(matrix, null), isNull);
  });

  testWidgets('the saved-session dialog says what to do with each sensor', (tester) async {
    const dir = '/data/R4H_001/D0';
    final session = MonitorSession()
      ..setInfo({'battery': battery.toJson(), 'participants': '001'})
      ..setSnapshot({'status': 'saved', 'session_dir': dir})
      ..setSaved({'directory': dir, 'done': 9, 'files': ['session_manifest.json']});
    await tester.binding.setSurfaceSize(const Size(1400, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showSessionSummaryDialog(
              context,
              session: session,
              send: (command, [args = const {}]) async => {'ok': true},
              onNewSession: () {},
            ),
            child: const Text('abrir'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();

    expect(find.text('ANTES DE QUE SE VAYA EL PARTICIPANTE'), findsOneWidget);
    expect(find.textContaining('Descarga y copia a la carpeta de la sesión: Axivity AX3'), findsOneWidget);
    expect(find.textContaining('vuelve a inicializar para la vida libre: Parmay Matrix'), findsOneWidget);
    expect(find.textContaining('Parmay Matrix · Muñeca no dominante'), findsWidgets);
    expect(find.textContaining('Inicia su grabación de vida libre'), findsOneWidget);
    expect(find.textContaining('R4H_001_D0_matrix_wnd'), findsOneWidget);
  });
}
