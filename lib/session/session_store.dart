import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../services/lab_redcap_service.dart';
import 'csv_stream_writer.dart';

/// Folder of one laboratory session and the files written into it while it
/// runs.
///
/// The folder is created when the session starts, as
/// `<root>/<study code>_<participant>/<visit>` (`R4H_001/D0`), the layout
/// of the RUN4HEALTH guide that SAVES opens directly. Everything is written
/// as it happens: the session state (to resume after a crash), a log of
/// events, the manifest, the sync windows and the activity markers; the
/// Research Monitor streams the Polar files and moves the video there.
class SessionStore {
  SessionStore._(this.directory, this.fileStamp);

  final Directory directory;

  /// Part of the Polar and video file names shared by the whole session
  /// (also after resuming it).
  final String fileStamp;

  /// Last write that failed, shown to the operator.
  final ValueNotifier<String?> lastError = ValueNotifier(null);

  CsvStreamWriter? _events;
  Future<void> _queue = Future.value();

  static const stateFile = 'session_state.json';
  static const manifestFile = 'session_manifest.json';
  static const eventsFile = 'session_events.csv';
  static const eventsHeader =
      'time_utc,time_local,event,activity_index,attempt,phase,detail';

  String get path => directory.path;

  String pathOf(String name) => '${directory.path}${Platform.pathSeparator}$name';

  // ===========================================================================
  // Folder names
  // ===========================================================================

  /// Short code of a study for folder names.
  static String studyCode(String? study) {
    final s = (study ?? '').trim();
    return switch (s.toUpperCase()) {
      'RUN4HEALTH' => 'R4H',
      'WEARGAP' => 'WG',
      '' => '',
      _ => safeName(s),
    };
  }

  /// `D0`, `D8` or the REDCap event name.
  static String visitCode(String eventName) {
    final match = RegExp(r'^da_(\d+)_').firstMatch(eventName);
    if (match != null) return 'D${match.group(1)}';
    return safeName(eventName.isEmpty ? 'visita' : eventName);
  }

  /// Removes characters Windows does not allow in names.
  static String safeName(String text) {
    final cleaned = text
        .trim()
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), '_');
    final trimmed = cleaned.replaceAll(RegExp(r'[. ]+$'), '');
    return trimmed.isEmpty ? '_' : trimmed;
  }

  /// `R4H_001` (or `001+002` for several participants without a study).
  static String participantFolder(String? study, List<ParticipantEntry> participants) {
    final ids = participants.map((p) => safeName(p.participantId)).join('+');
    final code = studyCode(study);
    return code.isEmpty ? ids : '${code}_$ids';
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  /// File-name stamp of a local time: `2026-10-21T09-30-05`.
  static String stampOf(DateTime time) {
    final t = time.toLocal();
    return '${t.year}-${_two(t.month)}-${_two(t.day)}T'
        '${_two(t.hour)}-${_two(t.minute)}-${_two(t.second)}';
  }

  /// Folder for a new session. A visit folder that already holds a session
  /// is not reused: the new one gets the date and time.
  static Future<Directory> chooseFolder({
    required String root,
    required String? study,
    required List<ParticipantEntry> participants,
    DateTime? now,
  }) async {
    final sep = Platform.pathSeparator;
    final base = '$root$sep${participantFolder(study, participants)}';
    final visit = visitCode(participants.isEmpty ? '' : participants.first.redcapEventName);
    final plain = Directory('$base$sep$visit');
    if (!await _holdsSession(plain)) return plain;
    final t = (now ?? DateTime.now()).toLocal();
    final suffix = '${t.year}${_two(t.month)}${_two(t.day)}-${_two(t.hour)}${_two(t.minute)}';
    var candidate = Directory('$base$sep${visit}_$suffix');
    var n = 2;
    while (await _holdsSession(candidate)) {
      candidate = Directory('$base$sep${visit}_${suffix}_$n');
      n++;
    }
    return candidate;
  }

  static Future<bool> _holdsSession(Directory dir) async {
    if (!await dir.exists()) return false;
    final sep = Platform.pathSeparator;
    return await File('${dir.path}$sep$stateFile').exists() ||
        await File('${dir.path}$sep$manifestFile').exists();
  }

  // ===========================================================================
  // Opening
  // ===========================================================================

  static Future<SessionStore> create(Directory directory, {DateTime? now}) async {
    await directory.create(recursive: true);
    final store = SessionStore._(directory, stampOf(now ?? DateTime.now()));
    store._openEvents();
    return store;
  }

  /// Opens the folder of a session to resume it.
  static SessionStore reopen(Directory directory, String fileStamp) {
    final store = SessionStore._(directory, fileStamp);
    store._openEvents();
    return store;
  }

  void _openEvents() {
    _events = CsvStreamWriter(pathOf(eventsFile), eventsHeader);
  }

  /// Reads the saved state of a session folder, or null.
  static Future<Map<String, dynamic>?> readState(String directory) async {
    try {
      final file = File('$directory${Platform.pathSeparator}$stateFile');
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (e) {
      debugPrint('[STORE] No se pudo leer el estado de $directory: $e');
      return null;
    }
  }

  // ===========================================================================
  // Writing
  // ===========================================================================

  /// Writes a whole file safely: a temporary copy first, then renamed over
  /// the old one, so a crash never leaves half a file. Retried a few times
  /// (synced drives lock files for a moment).
  static Future<void> writeAtomic(String path, String content) async {
    final tmp = File('$path.tmp');
    Object? error;
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        await tmp.writeAsString(content, flush: true);
        try {
          await tmp.rename(path);
        } on FileSystemException {
          final target = File(path);
          if (await target.exists()) await target.delete();
          await tmp.rename(path);
        }
        return;
      } catch (e) {
        error = e;
        await Future.delayed(Duration(milliseconds: 80 * (1 << attempt)));
      }
    }
    throw FileSystemException('No se pudo escribir: $error', path);
  }

  /// Queued writes, one at a time and in order; errors go to [lastError].
  Future<void> _enqueue(String name, Future<void> Function() write) {
    final done = Completer<void>();
    _queue = _queue.then((_) async {
      try {
        await write();
        if (lastError.value != null && lastError.value!.startsWith(name)) {
          lastError.value = null;
        }
      } catch (e) {
        debugPrint('[STORE] Error escribiendo $name: $e');
        lastError.value = '$name: $e';
      } finally {
        done.complete();
      }
    });
    return done.future;
  }

  Future<void> writeText(String name, String content) =>
      _enqueue(name, () => writeAtomic(pathOf(name), content));

  Future<void> writeJson(String name, Object json) =>
      writeText(name, const JsonEncoder.withIndent('  ').convert(json));

  /// Waits for the writes queued so far.
  Future<void> drain() => _queue;

  void logEvent(
    String event, {
    int? activityIndex,
    int? attempt,
    String? phase,
    String? detail,
    DateTime? time,
  }) {
    final t = (time ?? DateTime.now()).toUtc();
    final local = t.toLocal();
    final localText = '${_two(local.hour)}:${_two(local.minute)}:${_two(local.second)}';
    _events?.add([
      t.toIso8601String(),
      localText,
      csvField(event),
      activityIndex ?? '',
      attempt ?? '',
      phase ?? '',
      csvField(detail),
    ].join(','));
  }

  Future<void> flushEvents() async => _events?.flush();

  Future<void> close() async {
    await _events?.close();
    _events = null;
    await drain();
  }
}
