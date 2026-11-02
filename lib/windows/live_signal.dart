import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// Last [window] of one signal, sample by sample, for the live charts.
///
/// Every sample the sensor sends is kept (no downsampling on arrival): at
/// 130 Hz an ECG strip of 6 s is 780 samples, and at 200 Hz an ACC window of
/// 10 s is 2000. Reducing them to the pixels of the chart happens when it is
/// painted ([columnEnvelope]), keeping the minimum and maximum of each pixel
/// column so that R peaks and impacts are never lost.
class SignalBuffer {
  final Duration window;
  final int capacity;

  final Float64List _t;
  final Float64List _v;
  int _start = 0;
  int _length = 0;

  /// Changes each time a sample arrives; the monitor repaints when it moves.
  int revision = 0;

  SignalBuffer._(this.window, this.capacity)
      : _t = Float64List(capacity),
        _v = Float64List(capacity);

  /// [maxRateHz] sizes the buffer (with room for 50 % more samples).
  factory SignalBuffer({required Duration window, required double maxRateHz}) =>
      SignalBuffer._(
        window,
        math.max(16, (window.inMicroseconds / 1e6 * maxRateHz * 1.5).ceil()),
      );

  int get length => _length;
  bool get isEmpty => _length == 0;

  /// Time of the sample [i] (0 = oldest), in microseconds since the epoch.
  double timeAt(int i) => _t[(_start + i) % capacity];
  double valueAt(int i) => _v[(_start + i) % capacity];

  double? get lastValue => _length == 0 ? null : valueAt(_length - 1);
  double? get lastTime => _length == 0 ? null : timeAt(_length - 1);

  void add(DateTime time, double value) =>
      addMicros(time.microsecondsSinceEpoch.toDouble(), value);

  void addMicros(double timeMicros, double value) {
    // A sample older than the last one (clock correction) restarts the trace.
    if (_length > 0 && timeMicros < timeAt(_length - 1)) clear();
    final index = (_start + _length) % capacity;
    _t[index] = timeMicros;
    _v[index] = value;
    if (_length < capacity) {
      _length++;
    } else {
      _start = (_start + 1) % capacity;
    }
    // Drop what has left the window.
    final oldest = timeMicros - window.inMicroseconds;
    while (_length > 1 && timeAt(0) < oldest) {
      _start = (_start + 1) % capacity;
      _length--;
    }
    revision++;
  }

  void clear() {
    _start = 0;
    _length = 0;
    revision++;
  }
}

/// Minimum, maximum, first and last value of the samples that fall in each
/// pixel column of a chart [columns] wide that ends at [endMicros].
class ColumnEnvelope {
  final Float64List first;
  final Float64List last;
  final Float64List min;
  final Float64List max;
  final Uint8List filled;
  final double lowest;
  final double highest;

  ColumnEnvelope._(this.first, this.last, this.min, this.max, this.filled,
      this.lowest, this.highest);

  bool get isEmpty => lowest > highest;
}

/// Reduces [buffer] to one envelope per pixel column. Each sample goes to
/// exactly one column, so a single-sample spike still reaches its column's
/// maximum (an R peak is 1-3 samples at 130 Hz).
ColumnEnvelope columnEnvelope(
  SignalBuffer buffer, {
  required int columns,
  required double endMicros,
  required Duration window,
}) {
  final n = math.max(1, columns);
  final first = Float64List(n);
  final last = Float64List(n);
  final lo = Float64List(n);
  final hi = Float64List(n);
  final filled = Uint8List(n);
  var lowest = double.infinity;
  var highest = double.negativeInfinity;
  final span = window.inMicroseconds.toDouble();
  final startMicros = endMicros - span;

  for (var i = 0; i < buffer.length; i++) {
    final t = buffer.timeAt(i);
    if (t < startMicros) continue;
    final v = buffer.valueAt(i);
    final c = math.min(n - 1, ((t - startMicros) / span * n).floor());
    if (filled[c] == 0) {
      filled[c] = 1;
      first[c] = v;
      lo[c] = v;
      hi[c] = v;
    } else {
      if (v < lo[c]) lo[c] = v;
      if (v > hi[c]) hi[c] = v;
    }
    last[c] = v;
    if (v < lowest) lowest = v;
    if (v > highest) highest = v;
  }
  return ColumnEnvelope._(first, last, lo, hi, filled, lowest, highest);
}

/// Notifies the charts once per frame, only when some buffer changed.
class LiveFrameClock extends ChangeNotifier {
  void tick() => notifyListeners();
}
