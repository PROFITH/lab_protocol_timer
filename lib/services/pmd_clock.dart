import 'dart:math' as math;

/// Maps the clock of a Polar sensor (PMD timestamps) to the host clock.
///
/// Each PMD frame is stamped with the sensor time of its last sample and is
/// sent as soon as it is full, so `arrival - last sample` (the candidate) is
/// the clock offset plus the Bluetooth delay of that frame, which is never
/// negative. The offset is the lower envelope of the candidates:
///
/// * a candidate below the offset brings it down at once during the
///   [warmup], and then by at most 90 % of what the sensor clock advanced
///   since the frame before, so the timestamps of every stream keep
///   increasing (at least at a tenth of the speed while it comes down);
/// * the offset rises only as fast as two clocks can drift apart
///   ([maxDriftPpm]), whatever the candidates say.
///
/// So a Bluetooth link that falls behind (on 02/11/2026 an H10 delivered its
/// frames up to 17 s late for half a minute, twice) delays the frames but
/// not their timestamps. The method before took the minimum of the last
/// 30 s and started again when a candidate was more than 5 s above it: a
/// delay longer than 5 s, or longer than 30 s, moved every timestamp by the
/// delay.
class PmdClockMapper {
  PmdClockMapper({
    this.warmup = const Duration(seconds: 3),
    this.maxDriftPpm = 150,
  });

  final Duration warmup;

  /// How fast the offset may rise: two quartz clocks drift less than this.
  final double maxDriftPpm;

  int? _firstArrivalMicros;
  int? _lastArrivalMicros;
  int? _maxSensorMicros;
  int? _offsetMicros;

  /// Last values, for the clock log and the monitor.
  int? lastCandidateMicros;
  int? lastEstimateMicros;

  bool get isCalibrated => _offsetMicros != null;

  /// Offset in use: host µs = sensor µs + offset.
  int? get offsetMicros => _offsetMicros;

  /// Host time (UTC µs) when the last frame arrived.
  int? get lastArrivalMicros => _lastArrivalMicros;

  void reset() {
    _firstArrivalMicros = null;
    _lastArrivalMicros = null;
    _maxSensorMicros = null;
    _offsetMicros = null;
    lastCandidateMicros = null;
    lastEstimateMicros = null;
  }

  /// Registers one frame: when it arrived (host UTC µs) and the sensor time
  /// of its last sample (µs).
  void observe({required int arrivalHostMicros, required int lastSampleSensorMicros}) {
    final candidate = arrivalHostMicros - lastSampleSensorMicros;

    // The sensor clock went back (a reset or another sensor) or jumped
    // ahead of the host: start again. Frames of different streams arrive
    // out of order by less than a second.
    final maxSensor = _maxSensorMicros;
    if (_offsetMicros != null &&
        ((maxSensor != null && lastSampleSensorMicros < maxSensor - 2 * 1000 * 1000) ||
            candidate < _offsetMicros! - 5 * 1000 * 1000)) {
      reset();
    }
    lastCandidateMicros = candidate;
    final advanced = math.max(0, lastSampleSensorMicros - (_maxSensorMicros ?? lastSampleSensorMicros));
    _maxSensorMicros = math.max(_maxSensorMicros ?? lastSampleSensorMicros, lastSampleSensorMicros);
    _firstArrivalMicros ??= arrivalHostMicros;

    final offset = _offsetMicros;
    if (offset == null) {
      _offsetMicros = candidate;
    } else {
      final elapsed = math.max(0, arrivalHostMicros - (_lastArrivalMicros ?? arrivalHostMicros));
      final ceiling = offset + (elapsed * maxDriftPpm / 1e6).ceil();
      var next = math.min(candidate, ceiling);
      final warming = arrivalHostMicros - _firstArrivalMicros! < warmup.inMicroseconds;
      final floor = offset - (advanced * 0.9).floor();
      if (!warming && next < floor) next = floor;
      _offsetMicros = next;
    }
    lastEstimateMicros = _offsetMicros;
    _lastArrivalMicros = arrivalHostMicros;
  }

  /// Host UTC µs of a sensor time (µs). Before the first frame the sensor
  /// time is returned unchanged.
  int toHostMicros(int sensorMicros) => sensorMicros + (_offsetMicros ?? 0);

  DateTime toHostUtc(int sensorNanos) => DateTime.fromMicrosecondsSinceEpoch(
        toHostMicros(sensorNanos ~/ 1000),
        isUtc: true,
      );

  /// How late the last frame arrived beyond the usual Bluetooth latency
  /// (µs): what the link has fallen behind.
  int? get lastExcessLatencyMicros =>
      lastCandidateMicros == null || _offsetMicros == null
          ? null
          : math.max(0, lastCandidateMicros! - _offsetMicros!);
}
