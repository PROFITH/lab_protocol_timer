// Writes the folder of a whole RUN4HEALTH session (fake clock) for the SAVES
// tests: FIXTURE_OUT=/some/dir flutter test test/tools/write_fixture_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lab_protocol_timer/models/activity_battery.dart';
import 'package:lab_protocol_timer/services/lab_redcap_service.dart';
import 'package:lab_protocol_timer/session/protocol_engine.dart';
import 'package:lab_protocol_timer/session/session_clock.dart';
import 'package:lab_protocol_timer/session/session_controller.dart';

void main() {
  final out = Platform.environment['FIXTURE_OUT'];

  test('write a session folder', () async {
    if (out == null) return;
    final base = ActivityBattery.parse(File('assets/protocols/run4health_base.json').readAsStringSync());
    // Jumps where the posture allows them, claps lying and sitting.
    final battery = base.copyWith(sync: base.sync.copyWith(kind: SyncKind.jump));
    final clock = FakeSessionClock(DateTime.utc(2026, 10, 21, 8, 30));
    final c = SessionController(
      participants: [ParticipantEntry(participantId: '001', redcapEventName: 'da_0__visita_inici_arm_1')],
      battery: battery,
      dataRoot: out,
      operator: 'Técnica',
      clock: clock,
      redcapConfigured: false,
    );
    expect((await c.command('start', {'video': true})).ok, isTrue);
    for (var i = 0; i < 40000 && !c.engine.protocolComplete; i++) {
      clock.advance(const Duration(milliseconds: 100));
      c.tick();
      final pending = c.pendingRpeLog;
      if (pending != null) await c.command('annotate', {'log_index': pending, 'rpe': 3});
      if (c.engine.phase == SessionPhase.wait && !c.engine.protocolComplete && c.engine.isRunning) {
        // A few seconds of rest before the next activity.
        for (var k = 0; k < 50; k++) {
          clock.advance(const Duration(milliseconds: 100));
          c.tick();
        }
        await c.command('advance');
      }
    }
    expect(c.engine.protocolComplete, isTrue);
    await c.finish();
    c.dispose();
    stdout.writeln('FIXTURE ${c.store!.path}');
  });
}
