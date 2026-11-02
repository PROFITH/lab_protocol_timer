import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:lab_protocol_timer/services/pmd_clock.dart';

void main() {
  /// Frames of 36 samples at 200 Hz (180 ms). The sensor clock is
  /// [offsetUs] behind the host and runs [driftPpm] fast; each frame
  /// arrives 15 ms plus a random delay after its last sample.
  List<int> simulate(
    PmdClockMapper mapper, {
    required int frames,
    int offsetUs = 123456789,
    double driftPpm = 40,
    int seed = 1,
    List<int>? errorsUs,
  }) {
    final random = math.Random(seed);
    final mapped = <int>[];
    const frameUs = 180000;
    const hostStartUs = 1760000000000000;
    for (var k = 0; k < frames; k++) {
      final hostUs = hostStartUs + k * frameUs;
      final sensorUs = ((hostUs - offsetUs) * (1 + driftPpm / 1e6)).round();
      final latencyUs = 15000 + (-math.log(1 - random.nextDouble()) * 20000).round();
      mapper.observe(
        arrivalHostMicros: hostUs + latencyUs,
        lastSampleSensorMicros: sensorUs,
      );
      // First and last sample of the frame.
      mapped.add(mapper.toHostMicros(sensorUs - 35 * 5000));
      mapped.add(mapper.toHostMicros(sensorUs));
      errorsUs?.add(mapper.toHostMicros(sensorUs) - hostUs);
    }
    return mapped;
  }

  test('after the warm-up the error is close to the minimum latency', () {
    final mapper = PmdClockMapper();
    final errors = <int>[];
    simulate(mapper, frames: 20000, errorsUs: errors); // one hour
    final steady = errors.skip(200).toList();
    // Never earlier than the true time by more than the slew, never later
    // than the minimum latency plus a little.
    expect(steady.reduce(math.min), greaterThan(13000));
    expect(steady.reduce(math.max), lessThan(20000));
  });

  test('follows a 40 ppm drift over an hour (old method: 144 ms off)', () {
    final mapper = PmdClockMapper();
    final errors = <int>[];
    simulate(mapper, frames: 20000, errorsUs: errors);
    expect(errors.last, inInclusiveRange(14000, 20000));
  });

  test('timestamps always increase across frames', () {
    final mapper = PmdClockMapper();
    final mapped = simulate(mapper, frames: 5000, seed: 7);
    for (var i = 1; i < mapped.length; i++) {
      expect(mapped[i], greaterThan(mapped[i - 1]), reason: 'index $i');
    }
  });

  test('a jump of the sensor clock (reconnection) starts again', () {
    final mapper = PmdClockMapper();
    simulate(mapper, frames: 500);
    final before = mapper.offsetMicros!;
    simulate(mapper, frames: 50, offsetUs: 999999999);
    expect((mapper.offsetMicros! - before).abs(), greaterThan(800000000));
  });

  test('a link that falls 17 s behind for 40 s does not move the timestamps', () {
    final mapper = PmdClockMapper();
    const frameUs = 180000;
    const offsetUs = 555000;
    final errors = <int>[];
    for (var k = 0; k < 2000; k++) {
      final hostUs = 1760000000000000 + k * frameUs;
      final sensorUs = hostUs - offsetUs;
      // From frame 500 the delay grows to 17 s, stays 40 s and catches up.
      final behind = k < 500
          ? 0
          : k < 560
              ? (k - 500) * 283000
              : k < 780
                  ? 17000000
                  : math.max(0, 17000000 - (k - 780) * 800000);
      mapper.observe(arrivalHostMicros: hostUs + 15000 + behind, lastSampleSensorMicros: sensorUs);
      errors.add(mapper.toHostMicros(sensorUs) - hostUs);
      if (k == 700) expect(mapper.lastExcessLatencyMicros, greaterThan(16000000));
    }
    expect(errors.skip(100).reduce(math.max), lessThan(30000));
    expect(errors.skip(100).reduce(math.min), greaterThan(14000));
  });

  test('follows a sensor that runs slow (-60 ppm) for an hour', () {
    final mapper = PmdClockMapper();
    final errors = <int>[];
    simulate(mapper, frames: 20000, driftPpm: -60, errorsUs: errors);
    expect(errors.skip(200).reduce(math.max), lessThan(25000));
    expect(errors.skip(200).reduce(math.min), greaterThan(10000));
  });

  test('the frames of the H10 test of 02/11/2026: times stay on the lower envelope', () {
    // Arrival and sensor time of every frame of a session in which the
    // link fell up to 17 s behind twice and the old mapper moved the
    // timestamps by up to 13.6 s.
    final rows = File('test/fixtures/h10_polar_clock_2026-11-02.csv').readAsLinesSync().skip(1);
    final frames = [
      for (final row in rows)
        if (row.trim().isNotEmpty)
          (
            DateTime.parse(row.split(',')[0]).microsecondsSinceEpoch,
            int.parse(row.split(',')[2]) ~/ 1000,
          ),
    ];
    final best = frames.map((f) => f.$1 - f.$2).reduce(math.min);
    final mapper = PmdClockMapper();
    var runningMin = 1 << 62;
    var worstBehindRunningMin = 0;
    final errors = <int>[];
    for (final (arrival, sensor) in frames) {
      mapper.observe(arrivalHostMicros: arrival, lastSampleSensorMicros: sensor);
      runningMin = math.min(runningMin, arrival - sensor);
      worstBehindRunningMin = math.max(worstBehindRunningMin, mapper.offsetMicros! - runningMin);
      errors.add(mapper.offsetMicros! - best);
    }
    // The stream started 17 s behind, so nothing better was known until the
    // link caught up (frame ~630); the offset follows the best frame seen
    // so far within 0.3 s (19 ms here), and once it reached the lower envelope of the
    // whole session it stays within 0.1 s, also while the link is 17 s
    // behind again (where the old mapper moved the times by 13.6 s).
    expect(worstBehindRunningMin, lessThan(300000));
    final settled = errors.indexWhere((e) => e < 100000);
    expect(settled, greaterThan(0));
    for (final e in errors.skip(settled)) {
      expect(e.abs(), lessThan(100000));
    }
  });
}
