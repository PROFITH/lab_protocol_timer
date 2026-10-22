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
}
