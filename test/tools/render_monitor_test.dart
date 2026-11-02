// Renders the Research Monitor console in each state to PNG for a visual
// check: FIGURES_OUT=/some/dir flutter test test/tools/render_monitor_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lab_protocol_timer/models/activity_battery.dart';
import 'package:lab_protocol_timer/services/lab_redcap_service.dart';
import 'package:lab_protocol_timer/session/session_clock.dart';
import 'package:lab_protocol_timer/session/session_controller.dart';
import 'package:lab_protocol_timer/windows/monitor_session.dart';
import 'package:lab_protocol_timer/windows/session_console.dart';

import '../support/loopback_monitor.dart';
import 'render_participant_test.dart' show loadFonts;

void main() {
  final out = Platform.environment['FIGURES_OUT'];

  testWidgets('render monitor console', (tester) async {
    if (out == null) return;
    await tester.runAsync(loadFonts);
    final battery = ActivityBattery.parse(File('assets/protocols/run4health_base.json').readAsStringSync());
    final root = await tester.runAsync(() => Directory.systemTemp.createTemp('lpt_console_'));
    final clock = FakeSessionClock();
    final session = MonitorSession();
    final link = LoopbackMonitor(session);
    final c = SessionController(
      participants: [ParticipantEntry(participantId: '001', redcapEventName: 'da_0__visita_inici_arm_1')],
      battery: battery,
      dataRoot: root!.path,
      operator: 'Ana (técnica)',
      clock: clock,
      monitor: link,
      redcapConfigured: true,
      importRecords: (_) async => null,
    );
    Future<Map<String, dynamic>> send(String command, [Map<String, dynamic> args = const {}]) async {
      final result = await tester.runAsync(() => c.command(command, args));
      session.setSnapshot(c.snapshot());
      return result!.toJson();
    }

    var recording = false;
    var chips = <DeviceChip>[
      const DeviceChip(label: 'Cámara sala', detail: 'Sin preparar', color: Colors.white38, icon: Icons.videocam_rounded),
      const DeviceChip(label: 'Polar H10 · Pecho', detail: 'Sin conectar', color: Colors.white38, icon: Icons.favorite_rounded),
      const DeviceChip(label: 'Verity Sense · Brazo', detail: '71 lpm · ACC', color: Color(0xFF34D399), icon: Icons.favorite_rounded),
    ];
    final key = GlobalKey();
    late StateSetter rebuild;
    await tester.binding.setSurfaceSize(const Size(1500, 950));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(
          scaffoldBackgroundColor: const Color(0xFF07090E),
          colorScheme: const ColorScheme.dark(primary: Color(0xFF38BDF8), surface: Color(0xFF1E293B)),
          textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Roboto'),
        ),
        home: RepaintBoundary(
          key: key,
          child: StatefulBuilder(builder: (context, setState) {
            rebuild = setState;
            return Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SessionConsole(
                      session: session,
                      send: send,
                      onStart: () async {
                        await send('start', {'video': true});
                      },
                      devices: chips,
                      recording: recording,
                      onOpenFolder: (_) {},
                      onSettings: () {},
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            flex: 3,
                            child: Container(
                              decoration: BoxDecoration(
                                color: const Color(0xFF1E293B),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              alignment: Alignment.center,
                              child: const Text('(vídeo y gráficas en directo)', style: TextStyle(color: Colors.white24)),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 2,
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1E293B),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: ActivityPanel(session: session, send: send),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        ),
      ),
    );

    Future<void> shot(String name) async {
      session.setSnapshot(c.snapshot());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.runAsync(() async {
        final boundary = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 0.8);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('$out/monitor_$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      });
    }

    Future<void> dialogShot(String name) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(() async {
        // The dialog is in the overlay, outside the boundary: capture the
        // whole screen.
        final element = tester.element(find.byType(Dialog).last);
        final target = element.findAncestorRenderObjectOfType<RenderRepaintBoundary>();
        if (target != null) {
          final image = await target.toImage(pixelRatio: 0.8);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('$out/monitor_$name.png').writeAsBytes(bytes!.buffer.asUint8List());
        }
      });
    }

    void advance(double seconds) {
      final steps = (seconds * 10).round();
      for (var i = 0; i < steps; i++) {
        clock.advance(const Duration(milliseconds: 100));
        c.tick();
      }
    }

    await tester.runAsync(c.reannounce);
    await shot('0_idle');

    // Pre-flight check.
    final preflight = showPreflightDialog(
      key.currentContext!,
      items: const [
        PreflightItem('Cámara sala (cam_room)', true, 'Preparada · 1920×1080 · con audio', isCamera: true),
        PreflightItem('Polar H10 · Pecho (polar_h10)', false, 'Sin conectar: sus datos no se guardarán hasta que se conecte'),
        PreflightItem('Verity Sense · Brazo (verity_sense)', true, '71 lpm · ACC 52 Hz'),
        PreflightItem('REDCap', true, 'Se envía al finalizar (y se puede reintentar)'),
        PreflightItem('Espacio en disco', true, '182.4 GB libres en la carpeta de datos'),
        PreflightItem('AX3 · Muslo derecho (ax3_thigh)', true, 'Graba por su cuenta: comprueba que está colocado y grabando', manual: true),
        PreflightItem('AX6 · Zapatilla izquierda (ax6_left)', true, 'Graba por su cuenta: comprueba que está colocado y grabando', manual: true),
      ],
      cameraReady: true,
    );
    await dialogShot('1_preflight');
    Navigator.of(key.currentContext!).pop(true);
    await preflight;

    rebuild(() {
      recording = true;
      chips = [
        const DeviceChip(label: 'Cámara sala', detail: 'Grabando', color: Color(0xFFF87171), icon: Icons.fiber_manual_record_rounded),
        const DeviceChip(label: 'Polar H10 · Pecho', detail: '64 lpm · ACC', color: Color(0xFF34D399), icon: Icons.favorite_rounded),
        const DeviceChip(label: 'Verity Sense · Brazo', detail: 'Reconectando...', color: Colors.orangeAccent, icon: Icons.favorite_rounded, warning: true),
      ];
    });
    await send('start', {'video': true});
    advance(4);
    await shot('2_prep');
    advance(20);
    await shot('3_main_rest');
    advance(310);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    advance(40);
    await shot('4_wait_borg');
    await send('annotate', {'log_index': 0, 'rpe': 1});
    await tester.tap(find.text('Tumbado en reposo').first);
    await shot('5_wait_editor');
    await tester.tap(find.text('Tumbado en reposo').first);
    await send('advance');
    advance(35);
    await shot('6_main_stand');
    await send('pause');
    await shot('7_paused');
    await send('resume');
    advance(400);
    await send('annotate', {'log_index': 1, 'rpe': 1});
    await send('goto', {'index': 7});
    advance(40);
    await shot('8_main_run');

    // FINALIZAR Y GUARDAR with activities missing.
    await tester.tap(find.textContaining('FINALIZAR'));
    await dialogShot('9_finish_confirm');
    await tester.tap(find.text('Volver').last);
    await tester.pump();

    // The end: summary.
    var done = false;
    // finish() mixes real file IO with timers of the fake zone: both clocks
    // have to move while it runs.
    final finishing = c.finish().whenComplete(() => done = true);
    for (var i = 0; i < 400 && !done; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await finishing;
    session.setSnapshot(c.snapshot());
    final summary = showSessionSummaryDialog(
      key.currentContext!,
      session: session,
      send: send,
      onOpenFolder: (_) {},
      onNewSession: () {},
    );
    await dialogShot('10_summary');
    Navigator.of(key.currentContext!).pop();
    await summary;
    c.dispose();
    await tester.runAsync(() => root.delete(recursive: true));
  });
}
