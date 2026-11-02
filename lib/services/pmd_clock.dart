import 'dart:collection';
import 'dart:math' as math;

/// Maps the clock of a Polar sensor (PMD timestamps) to the host clock.
///
/// Each PMD frame is stamped with the sensor time of its last sample and is
/// sent as soon as it is full, so `arrival - last sample` is the clock
/// offset plus the Bluetooth latency of that frame, which is never negative.
/// The smallest of those values over the last [window] is the offset plus
/// the minimum latency (a few ms), and it follows the drift between the two
/// clocks.
///
/// The old method took the offset from the first sample of the first frame
/// against its arrival, which put every sample late by the length of a
/// frame (about 175 ms for ACC at 200 Hz and 560 ms for ECG) plus that
/// frame's latency, and never followed the drift.
///
/// After [warmup] the offset in use moves at most [maxSlewMicros] per frame,
/// less than one sample period, so timestamps always increase.
class PmdClockMapper {
  PmdClockMapper({
    this.window = const Duration(seconds: 30),
    this.warmup = const Duration(seconds: 3),
    this.maxSlewMicros = 2000,
  });

  final Duration window;
  final Duration warmup;
  final int maxSlewMicros;

  /// (arrival host µs, candidate offset µs), increasing offsets.
  final ListQueue<(int, int)> _candidates = ListQueue();

  int? _firstArrivalMicros;
  int? _offsetMicros;

  /// Last values, for the clock log.
  int? lastCandidateMicros;
  int? lastEstimateMicros;

  bool get isCalibrated => _offsetMicros != null;

  /// Offset in use: host µs = sensor µs + offset.
  int? get offsetMicros => _offsetMicros;

  void reset() {
    _candidates.clear();
    _firstArrivalMicros = null;
    _offsetMicros = null;
    lastCandidateMicros = null;
    lastEstimateMicros = null;
  }

  /// Registers one frame: when it arrived (host UTC µs) and the sensor time
  /// of its last sample (µs).
  void observe({required int arrivalHostMicros, required int lastSampleSensorMicros}) {
    final candidate = arrivalHostMicros - lastSampleSensorMicros;
    lastCandidateMicros = candidate;

    // A reconnection or a sensor clock reset: start again.
    if (_offsetMicros != null &&
        (candidate - _offsetMicros!).abs() > 5 * 1000 * 1000) {
      reset();
      lastCandidateMicros = candidate;
    }

    while (_candidates.isNotEmpty && _candidates.last.$2 >= candidate) {
      _candidates.removeLast();
    }
    _candidates.addLast((arrivalHostMicros, candidate));
    final oldest = arrivalHostMicros - window.inMicroseconds;
    while (_candidates.length > 1 && _candidates.first.$1 < oldest) {
      _candidates.removeFirst();
    }

    final estimate = _candidates.first.$2;
    lastEstimateMicros = estimate;
    _firstArrivalMicros ??= arrivalHostMicros;

    if (_offsetMicros == null ||
        arrivalHostMicros - _firstArrivalMicros! < warmup.inMicroseconds) {
      _offsetMicros = estimate;
    } else {
      final step = (estimate - _offsetMicros!).clamp(-maxSlewMicros, maxSlewMicros);
      _offsetMicros = _offsetMicros! + step;
    }
  }

  /// Host UTC µs of a sensor time (µs). Before the first frame the sensor
  /// time is returned unchanged.
  int toHostMicros(int sensorMicros) => sensorMicros + (_offsetMicros ?? 0);

  DateTime toHostUtc(int sensorNanos) => DateTime.fromMicrosecondsSinceEpoch(
        toHostMicros(sensorNanos ~/ 1000),
        isUtc: true,
      );

  /// Latency of the last frame above the best one in the window (µs).
  int? get lastExcessLatencyMicros =>
      lastCandidateMicros == null || lastEstimateMicros == null
          ? null
          : math.max(0, lastCandidateMicros! - lastEstimateMicros!);
}
