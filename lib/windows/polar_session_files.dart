import 'dart:async';
import 'dart:io';

import '../models/polar_hr_sample.dart';
import '../services/polar_ble_service.dart';
import '../session/csv_stream_writer.dart';

/// Streams the samples of one Polar device into the session folder while
/// the session runs: one file per signal (`polar_hr`, `polar_acc`,
/// `polar_ecg`, and on the Verity Sense `polar_ppg`, `polar_ppi`,
/// `polar_gyro`, `polar_mag`), plus the clock and connection logs.
///
/// The service keeps every sample in memory as it arrives; this moves them
/// to the files about once a second and empties the lists, so a crash loses
/// at most a couple of seconds and an hour of ECG does not stay in memory.
/// The names carry the device ID of the session
/// (`polar_hr_<device>_<stamp>.csv`), which SAVES uses to match each file
/// with its sensor in the manifest.
class PolarSessionFiles {
  PolarSessionFiles({
    required this.directory,
    required this.stamp,
    required this.deviceId,
    required this.service,
  });

  final String directory;
  final String stamp;
  final String deviceId;
  final PolarBleService service;

  late final CsvStreamWriter hr = _writer('polar_hr', PolarHrSample.csvHeader);
  late final CsvStreamWriter acc = _writer('polar_acc', PolarAccelerationSample.csvHeader);
  late final CsvStreamWriter ecg = _writer('polar_ecg', PolarEcgSample.csvHeader);
  late final CsvStreamWriter ppg = _writer('polar_ppg', PolarPpgSample.csvHeader);
  late final CsvStreamWriter ppi = _writer('polar_ppi', PolarPpiSample.csvHeader);
  late final CsvStreamWriter gyro = _writer('polar_gyro', PolarGyroSample.csvHeader);
  late final CsvStreamWriter mag = _writer('polar_mag', PolarMagSample.csvHeader);
  late final CsvStreamWriter events =
      _writer('polar_connection_events', PolarConnectionEvent.csvHeader);
  late final CsvStreamWriter clock = _writer('polar_clock', PmdClockObservation.csvHeader);

  /// Heart rate of the last minutes, for the resting heart rate.
  final List<PolarHrSample> recentHr = [];
  static const recentSpan = Duration(minutes: 10);

  Timer? _timer;
  int _eventsWritten = 0;
  bool _stopped = false;

  List<CsvStreamWriter> get _writers => [hr, acc, ecg, ppg, ppi, gyro, mag, events, clock];

  CsvStreamWriter _writer(String kind, String header) => CsvStreamWriter(
        '$directory${Platform.pathSeparator}${kind}_${deviceId}_$stamp.csv',
        header,
      );

  /// Last write error of any of the files, for the operator.
  Object? get lastError {
    for (final w in _writers) {
      if (w.lastError != null) return w.lastError;
    }
    return null;
  }

  int get hrRows => hr.rows;
  int get accRows => acc.rows;
  int get ecgRows => ecg.rows;
  int get ppgRows => ppg.rows;
  int get ppiRows => ppi.rows;
  int get gyroRows => gyro.rows;
  int get magRows => mag.rows;

  void start() {
    // What arrived before the session is not part of it.
    service.recordedSamples.clear();
    service.recordedAccelerationSamples.clear();
    service.recordedEcgSamples.clear();
    service.recordedPpgSamples.clear();
    service.recordedPpiSamples.clear();
    service.recordedGyroSamples.clear();
    service.recordedMagSamples.clear();
    service.clockObservations.clear();
    // The connection history of the device is (a few rows).
    _eventsWritten = 0;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => drain());
  }

  /// Moves what the service received to the files.
  void drain() {
    if (_stopped) return;
    final hrSamples = service.recordedSamples;
    if (hrSamples.isNotEmpty) {
      for (final s in hrSamples) {
        hr.add(s.toCsvRow());
      }
      recentHr.addAll(hrSamples);
      hrSamples.clear();
      final oldest = DateTime.now().toUtc().subtract(recentSpan);
      final keep = recentHr.indexWhere((s) => !s.timestamp.isBefore(oldest));
      if (keep > 0) recentHr.removeRange(0, keep);
    }
    _move(service.recordedAccelerationSamples, acc, (s) => s.toCsvRow());
    _move(service.recordedEcgSamples, ecg, (s) => s.toCsvRow());
    _move(service.recordedPpgSamples, ppg, (s) => s.toCsvRow());
    _move(service.recordedPpiSamples, ppi, (s) => s.toCsvRow());
    _move(service.recordedGyroSamples, gyro, (s) => s.toCsvRow());
    _move(service.recordedMagSamples, mag, (s) => s.toCsvRow());
    _move(service.clockObservations, clock, (s) => s.toCsvRow());
    final history = service.connectionEvents;
    if (_eventsWritten > history.length) _eventsWritten = 0;
    while (_eventsWritten < history.length) {
      events.add(history[_eventsWritten++].toCsvRow());
    }
  }

  static void _move<T>(List<T> list, CsvStreamWriter writer, String Function(T) row) {
    if (list.isEmpty) return;
    for (final item in list) {
      writer.add(row(item));
    }
    list.clear();
  }

  /// Writes what is left and closes the files; returns those written.
  Future<List<String>> stop() async {
    if (!_stopped) {
      drain();
      _stopped = true;
      _timer?.cancel();
      _timer = null;
    }
    await Future.wait([for (final w in _writers) w.close()]);
    return [
      for (final w in _writers)
        if (w.rows > 0 && File(w.path).existsSync()) w.path,
    ];
  }

  /// Writes what arrived so far without closing (the app is closing).
  Future<void> flush() async {
    drain();
    await Future.wait([for (final w in _writers) w.flush()]);
  }

  /// Resting heart rate between [from] and [to], or null without data.
  RestingHeartRate? restingHeartRate(DateTime from, DateTime to) {
    drain();
    return RestingHeartRate.compute(
      [
        for (final s in recentHr)
          if (!s.timestamp.isBefore(from) && !s.timestamp.isAfter(to)) s,
      ],
    );
  }
}

/// Mean heart rate of a still period: from the RR intervals when the
/// sensor sends them (60000 / mean RR, without artefacts), otherwise the
/// mean of the heart rate it reports.
class RestingHeartRate {
  const RestingHeartRate(this.bpm, this.method, this.count);

  final int bpm;

  /// `rr` or `hr`.
  final String method;

  /// RR intervals or heart-rate values used.
  final int count;

  Map<String, dynamic> toJson() => {'bpm': bpm, 'method': method, 'n': count};

  static RestingHeartRate? compute(List<PolarHrSample> samples) {
    final rr = [
      for (final s in samples)
        for (final v in s.rrIntervalsMs)
          if (v >= 300 && v <= 2000) v,
    ];
    if (rr.length >= 20) {
      final sorted = [...rr]..sort();
      final median = sorted[sorted.length ~/ 2];
      // Missed or extra beats: more than 20 % away from the median.
      final clean = [for (final v in rr) if ((v - median).abs() <= 0.2 * median) v];
      if (clean.length >= 20) {
        final mean = clean.reduce((a, b) => a + b) / clean.length;
        return RestingHeartRate((60000 / mean).round(), 'rr', clean.length);
      }
    }
    final hr = [for (final s in samples) if (s.heartRateBpm >= 25 && s.heartRateBpm <= 230) s.heartRateBpm];
    if (hr.length < 10) return null;
    final mean = hr.reduce((a, b) => a + b) / hr.length;
    return RestingHeartRate(mean.round(), 'hr', hr.length);
  }
}
