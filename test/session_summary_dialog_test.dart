import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lab_protocol_timer/models/activity_battery.dart';
import 'package:lab_protocol_timer/windows/monitor_session.dart';
import 'package:lab_protocol_timer/windows/session_console.dart';

void main() {
  final battery = ActivityBattery.parse(File('test/fixtures/run4health_base_v2.json').readAsStringSync());

  test('after the session every lab sensor is downloaded and the free-living set is put on', () {
    // The fixture's old `free_living: true` reads as used in both.
    final after = SensorsAfterSession(battery.sensors);
    expect(after.download.map((s) => s.sensorId),
        ['matrix_wnd', 'ax3_wnd', 'ax3_wd', 'sens_thigh', 'ax3_thigh']);
    expect(after.downloadAndRestart, isEmpty);
    expect(after.startFreeLiving.map((s) => s.sensorId), ['matrix_wnd', 'sens_thigh', 'verity_arm']);
    expect(after.withoutSerial, hasLength(5));

    final matrix = after.download.first;
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
    expect(find.textContaining('Descarga y copia a la carpeta de la sesión: Parmay Matrix'), findsOneWidget);
    expect(find.textContaining('Ponle el juego de vida libre'), findsOneWidget);
    expect(find.textContaining('Parmay Matrix · Muñeca no dominante'), findsWidgets);
    expect(find.textContaining('R4H_001_D0_matrix_wnd'), findsOneWidget);
  });
}
