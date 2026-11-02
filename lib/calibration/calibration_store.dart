import 'dart:io';

/// A device calibrated: its type (`ax6`) and serial number.
class CalibrationDevice {
  const CalibrationDevice(this.type, this.serial);

  final String type;
  final String serial;

  /// `ax6:12345`, as written in the calibration CSV.
  String get code => '$type:$serial';

  static CalibrationDevice? parse(String code) {
    final i = code.indexOf(':');
    if (i <= 0 || i == code.length - 1) return null;
    return CalibrationDevice(code.substring(0, i).trim(), code.substring(i + 1).trim());
  }

  bool matches(String type, String? serial) =>
      serial != null && this.type == type && this.serial == serial.trim();

  @override
  bool operator ==(Object other) =>
      other is CalibrationDevice && other.type == type && other.serial == serial;

  @override
  int get hashCode => Object.hash(type, serial);
}

/// One calibration of the offline sensors in the dodecahedron, done by the
/// technician before the participants arrive or after they leave. It is
/// recorded on the sensors themselves; this app keeps when each face
/// started and ended, in this computer's clock, so the analysis (GGIR
/// calibration coefficients) can find the still segments.
class CalibrationRecord {
  CalibrationRecord({
    required this.file,
    required this.start,
    required this.end,
    required this.faces,
    required this.completed,
    this.devices = const [],
  });

  /// CSV of the calibration (`calibracion_<stamp>.csv`).
  final File file;
  final DateTime start;
  final DateTime end;
  final int faces;

  /// Every face was done (not cancelled half-way).
  final bool completed;

  /// Devices that were inside the dodecahedron, with their serial numbers.
  final List<CalibrationDevice> devices;

  String get fileName => file.uri.pathSegments.last;

  /// Whether the device of [type] with [serial] was in this calibration.
  bool includes(String type, String? serial) => devices.any((d) => d.matches(type, serial));

  /// Reads the first and last time of a calibration CSV written by
  /// [CalibrationWriter]; null when the file is not one.
  static Future<CalibrationRecord?> read(File file) async {
    try {
      final lines = (await file.readAsLines())
          .where((l) => l.trim().isNotEmpty)
          .toList();
      if (lines.length < 2 || !lines.first.startsWith('event,')) return null;
      final rows = [for (final l in lines.skip(1)) l.split(',')];
      DateTime? first;
      DateTime? last;
      var faces = 0;
      var completed = false;
      final devices = <CalibrationDevice>[];
      for (final r in rows) {
        if (r.length < 3) continue;
        final t = DateTime.tryParse(r[2]);
        if (t == null) continue;
        first ??= t;
        last = t;
        if (r[0] == 'face_start') faces++;
        if (r[0] == 'device' && r.length > 4) {
          if (CalibrationDevice.parse(r[4]) case final d?) devices.add(d);
        }
        if (r[0] == 'calibration_end') completed = true;
      }
      if (first == null || last == null) return null;
      return CalibrationRecord(
        file: file,
        start: first,
        end: last,
        faces: faces,
        completed: completed,
        devices: devices,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Where calibrations wait for their session: `calibraciones/` under the
/// parent folder. When a session starts, each calibration used is moved to
/// the folders of the participants whose sensors it has.
class CalibrationStore {
  static const folderName = 'calibraciones';
  static const filePrefix = 'calibracion_';

  /// A calibration older than this is not taken as the one before a
  /// session (the sensors are charged and calibrated on the day).
  static const maxAge = Duration(hours: 12);

  static Directory folderOf(String dataRoot) =>
      Directory('$dataRoot${Platform.pathSeparator}$folderName');

  /// Every calibration under [dataRoot], newest first.
  static Future<List<CalibrationRecord>> list(String dataRoot) async {
    final dir = folderOf(dataRoot);
    if (!await dir.exists()) return const [];
    final records = <CalibrationRecord>[];
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!name.startsWith(filePrefix) || !name.endsWith('.csv')) continue;
      final r = await CalibrationRecord.read(entity);
      if (r != null) records.add(r);
    }
    records.sort((a, b) => b.end.compareTo(a.end));
    return records;
  }

  /// Complete calibrations that ended before [at] and less than [maxAge]
  /// earlier, newest first (the technician may calibrate in batches when
  /// not every sensor fits in the dodecahedron).
  static Future<List<CalibrationRecord>> recentBefore(String dataRoot, DateTime at) async => [
        for (final r in await list(dataRoot))
          if (r.completed && !r.end.isAfter(at) && at.difference(r.end) <= maxAge) r,
      ];

  /// The newest of [records] with the device of [type] and [serial].
  static CalibrationRecord? forDevice(
    Iterable<CalibrationRecord> records,
    String type,
    String? serial,
  ) {
    CalibrationRecord? best;
    for (final r in records) {
      if (!r.includes(type, serial)) continue;
      if (best == null || r.end.isAfter(best.end)) best = r;
    }
    return best;
  }

  /// Copies [record] into each of [folders], keeping its name.
  static Future<void> copyInto(CalibrationRecord record, Iterable<Directory> folders) async {
    final name = record.file.uri.pathSegments.last;
    for (final dir in folders) {
      await record.file.copy('${dir.path}${Platform.pathSeparator}$name');
    }
  }
}

/// Writes a calibration CSV as it happens: one row per event, in UTC and
/// in the computer's local time.
class CalibrationWriter {
  CalibrationWriter._(this.file, this._sink);

  final File file;
  final IOSink _sink;

  static String _two(int v) => v.toString().padLeft(2, '0');

  /// `calibracion_2026-11-03T08-15-00.csv` in the calibrations folder.
  static Future<CalibrationWriter> create(String dataRoot, DateTime now) async {
    final dir = CalibrationStore.folderOf(dataRoot);
    await dir.create(recursive: true);
    final t = now.toLocal();
    final stamp = '${t.year}-${_two(t.month)}-${_two(t.day)}T'
        '${_two(t.hour)}-${_two(t.minute)}-${_two(t.second)}';
    final file = File('${dir.path}${Platform.pathSeparator}'
        '${CalibrationStore.filePrefix}$stamp.csv');
    final sink = file.openWrite();
    sink.writeln('event,face,time_utc,time_local,detail');
    return CalibrationWriter._(file, sink);
  }

  /// Rows written one after another (a row may come while the previous
  /// one is still being flushed).
  Future<void> _last = Future.value();

  /// Adds one row and flushes it, so a crash keeps what was done.
  Future<void> log(String event, DateTime at, {int? face, String? detail}) {
    final clean = (detail ?? '').replaceAll(RegExp(r'[,\r\n]'), ' ');
    final row = '$event,${face ?? ''},${at.toUtc().toIso8601String()},'
        '${at.toLocal().toIso8601String()},$clean';
    return _last = _last.then((_) async {
      _sink.writeln(row);
      await _sink.flush();
    });
  }

  Future<void> close() => _last = _last.then((_) => _sink.close());
}
