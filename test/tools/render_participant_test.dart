// Renders the participant screen in each state to PNG for a visual check:
// FIGURES_OUT=/some/dir flutter test test/tools/render_participant_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lab_protocol_timer/models/activity_battery.dart';
import 'package:lab_protocol_timer/services/lab_redcap_service.dart';
import 'package:lab_protocol_timer/session/participant_view.dart';
import 'package:lab_protocol_timer/session/protocol_engine.dart';
import 'package:lab_protocol_timer/session/session_clock.dart';
import 'package:lab_protocol_timer/session/session_controller.dart';

Future<void> loadFonts() async {
  final roboto = Directory(
    '${Platform.environment['HOME']}/.pub-cache/hosted/pub.dev/provider-6.1.5+1/'
    'extension/devtools/build/assets/packages/devtools_app_shared/fonts/Roboto',
  );
  final loader = FontLoader('Roboto');
  for (final name in ['Regular', 'Medium', 'Bold', 'Black']) {
    final file = File('${roboto.path}/Roboto-$name.ttf');
    if (file.existsSync()) {
      loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    }
  }
  await loader.load();
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ??
      File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.path;
  final icons = File('$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (icons.existsSync()) {
    final iconLoader = FontLoader('MaterialIcons')
      ..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
    await iconLoader.load();
  }
}

void main() {
  final out = Platform.environment['FIGURES_OUT'];

  testWidgets('render participant screens', (tester) async {
    if (out == null) return;
    await tester.runAsync(loadFonts);
    final battery = ActivityBattery.parse(
      File('assets/protocols/run4health_base.json').readAsStringSync(),
    );
    final root = await tester.runAsync(() => Directory.systemTemp.createTemp('lpt_view_'));
    final clock = FakeSessionClock();
    final c = SessionController(
      participants: [ParticipantEntry(participantId: '001', redcapEventName: 'da_0__visita_inici_arm_1')],
      battery: battery,
      dataRoot: root!.path,
      clock: clock,
      redcapConfigured: false,
    );
    final key = GlobalKey();
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Roboto')),
        home: RepaintBoundary(
          key: key,
          child: Scaffold(body: ParticipantView(controller: c, onShowMonitor: () {})),
        ),
      ),
    );

    Future<void> shot(String name) async {
      // State changed outside a frame: the first pump starts the
      // transitions, the second lets them finish.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1200));
      await tester.runAsync(() async {
        final boundary = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 0.75);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('$out/participant_$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      });
    }

    // finish() mixes real file IO with timers created in the fake zone, so
    // both clocks have to move while it runs.
    Future<void> settle(Future<void> Function() action) async {
      var done = false;
      final future = action().whenComplete(() => done = true);
      for (var i = 0; i < 400 && !done; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await future;
    }

    void advance(double seconds) {
      final steps = (seconds * 10).round();
      for (var i = 0; i < steps; i++) {
        clock.advance(const Duration(milliseconds: 100));
        c.tick();
      }
    }

    await shot('0_idle');
    await tester.runAsync(() => c.command('start', {'video': true}));
    advance(4);
    await shot('1_prep');
    advance(9.2);
    await shot('2_cue_countdown');
    advance(2.2);
    await shot('3_cue_go');
    advance(20);
    await shot('4_main_lie');
    advance(300);
    await shot('5_post');
    advance(40);
    await shot('6_wait_borg');
    await tester.runAsync(() => c.command('annotate', {'log_index': 0, 'rpe': 1}));
    await shot('7_wait_next');
    await tester.runAsync(() => c.command('advance'));
    advance(31);
    await shot('8_main_stand');
    await tester.runAsync(() => c.command('pause'));
    await shot('9_paused');
    await tester.runAsync(() => c.command('resume'));
    // Jump to the chair stand: rpe before.
    advance(400);
    await tester.runAsync(() => c.command('annotate', {'log_index': 1, 'rpe': 1}));
    await tester.runAsync(() => c.command('goto', {'index': 8}));
    c.tick();
    await shot('10_wait_rpe_before');
    await tester.runAsync(() => c.command('rpe_before', {'index': 8, 'value': 1}));
    await tester.runAsync(() => c.command('advance'));
    advance(35);
    await shot('11_main_sit_to_stand');
    expect(c.engine.phase, SessionPhase.main);
    await settle(() => c.finish());
    await shot('12_end');
    c.dispose();
    await tester.runAsync(() => root.delete(recursive: true));
  });
}
