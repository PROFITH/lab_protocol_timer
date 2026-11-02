import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../services/lab_redcap_service.dart';
import 'csv_stream_writer.dart';

/// Folders of one laboratory session and the files written into them while
/// it runs.
///
/// Each participant has a folder, created when the session starts: by
/// default `<root>/<study code>_<participant>/<visit>` (`R4H_001/D0`), the
/// layout of the RUN4HEALTH guide that SAVES opens directly, or the folder
/// chosen for them in the session setup. Everything is written as it
/// happens: the session state (to resume after a crash), a log of events,
/// the manifest, the sync windows and the activity markers; the Research
/// Monitor streams each participant's Polar files into their folder and
/// copies the video to every folder.
///
/// What the session shares (state, events, markers, sync windows) is
/// written to every folder, so each one stands on its own and SAVES can
/// take any of them; the manifest of each folder lists its participant's
/// sensors. The first participant's folder is the [directory] of the
/// session (the one the start screen remembers and the monitor is told).
class SessionStore {
  SessionStore._(this.directory, this.fileStamp, Map<String, Directory> participantDirectories)
      : participantDirectories = Map.unmodifiable(participantDirectories);

  /// Folder of the first participant (the session's main folder).
  final Directory directory;

  /// Folder of each participant, by participant ID. Empty for a session
  /// with one folder for everybody (older sessions).
  final Map<String, Directory> participantDirectories;

  /// Part of the Polar and video file names shared by the whole session
  /// (also after resuming it).
  final String fileStamp;

  /// Last write that failed, shown to the operator.
  final ValueNotifier<String?> lastError = ValueNotifier(null);

  /// Clock of the event log (the session clock, so the log lines up with
  /// the activity and sync times).
  DateTime Function() now = DateTime.now;

  final List<CsvStreamWriter> _events = [];
  Future<void> _queue = Future.value();

  static const stateFile = 'session_state.json';
  static const manifestFile = 'session_manifest.json';
  static const eventsFile = 'session_events.csv';
  static const eventsHeader =
      'time_utc,time_local,event,activity_index,attempt,phase,detail';

  String get path => directory.path;

  String pathOf(String name) => '${directory.path}${Platform.pathSeparator}$name';

  /// Every folder of the session, the main one first, without repeats.
  List<Directory> get directories {
    final paths = <String>{directory.path};
    final all = [directory];
    for (final dir in participantDirectories.values) {
      if (paths.add(dir.path)) all.add(dir);
    }
    return all;
  }

  /// The folder of a participant (the main one when they have none).
  Directory directoryOf(String participantId) =>
      participantDirectories[participantId] ?? directory;

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

  /// The automatic folder of a participant's visit, as shown in the setup:
  /// `<root>/R4H_001/D0`.
  static String defaultFolder(String root, String? study, ParticipantEntry participant) {
    final sep = Platform.pathSeparator;
    return '$root$sep${participantFolder(study, [participant])}$sep'
        '${visitCode(participant.redcapEventName)}';
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
    return freeFolder('$base$sep$visit', now: now);
  }

  /// [path] unless it already holds a session; then a sibling with the
  /// date and time (`D0_20261021-0905`, `D0_20261021-0905_2`...).
  static Future<Directory> freeFolder(String path, {DateTime? now}) async {
    final plain = Directory(path);
    if (!await _holdsSession(plain)) return plain;
    final t = (now ?? DateTime.now()).toLocal();
    final suffix = '${t.year}${_two(t.month)}${_two(t.day)}-${_two(t.hour)}${_two(t.minute)}';
    var candidate = Directory('${path}_$suffix');
    var n = 2;
    while (await _holdsSession(candidate)) {
      candidate = Directory('${path}_${suffix}_$n');
      n++;
    }
    return candidate;
  }

  /// The folder of each participant of a new session: the one chosen for
  /// them, or the automatic one under [root]. Two participants never share
  /// a folder: a repeated one gets the participant ID appended.
  static Future<Map<String, Directory>> chooseFolders({
    required String root,
    required String? study,
    required List<ParticipantEntry> participants,
    DateTime? now,
  }) async {
    final chosen = <String, Directory>{};
    final taken = <String>{};
    for (final participant in participants) {
      final custom = participant.folder?.trim();
      var path = custom == null || custom.isEmpty
          ? defaultFolder(root, study, participant)
          : custom;
      if (taken.contains(path)) path = '${path}_${safeName(participant.participantId)}';
      final dir = await freeFolder(path, now: now);
      taken.add(path);
      chosen[participant.participantId] = dir;
    }
    return chosen;
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

  /// Creates the folders of a new session: [directory] (the main one) and,
  /// when given, the folder of each participant.
  static Future<SessionStore> create(
    Directory directory, {
    Map<String, Directory> participantDirectories = const {},
    DateTime? now,
  }) async {
    final store = SessionStore._(directory, stampOf(now ?? DateTime.now()), participantDirectories);
    for (final dir in store.directories) {
      await dir.create(recursive: true);
    }
    store._openEvents();
    return store;
  }

  /// Opens the folders of a session to resume it.
  static SessionStore reopen(
    Directory directory,
    String fileStamp, {
    Map<String, Directory> participantDirectories = const {},
  }) {
    final store = SessionStore._(directory, fileStamp, participantDirectories);
    store._openEvents();
    return store;
  }

  void _openEvents() {
    for (final dir in directories) {
      _events.add(CsvStreamWriter('${dir.path}${Platform.pathSeparator}$eventsFile', eventsHeader));
    }
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
  /// After [close] nothing more is written (the folder may be renamed).
  Future<void> _enqueue(String name, Future<void> Function() write) {
    if (_closed) {
      debugPrint('[STORE] $name no se escribe: la sesión ya está cerrada');
      return Future.value();
    }
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

  /// Writes [name] with [content] into every folder of the session.
  Future<void> writeText(String name, String content) => _enqueue(name, () async {
        for (final dir in directories) {
          await writeAtomic('${dir.path}${Platform.pathSeparator}$name', content);
        }
      });

  Future<void> writeJson(String name, Object json) =>
      writeText(name, const JsonEncoder.withIndent('  ').convert(json));

  /// Writes [name] into one folder only (a participant's manifest).
  Future<void> writeTextTo(Directory dir, String name, String content) =>
      _enqueue(name, () => writeAtomic('${dir.path}${Platform.pathSeparator}$name', content));

  Future<void> writeJsonTo(Directory dir, String name, Object json) =>
      writeTextTo(dir, name, const JsonEncoder.withIndent('  ').convert(json));

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
    final t = (time ?? now()).toUtc();
    final local = t.toLocal();
    final localText = '${_two(local.hour)}:${_two(local.minute)}:${_two(local.second)}';
    final row = [
      t.toIso8601String(),
      localText,
      csvField(event),
      activityIndex ?? '',
      attempt ?? '',
      phase ?? '',
      csvField(detail),
    ].join(',');
    for (final writer in _events) {
      writer.add(row);
    }
  }

  Future<void> flushEvents() async {
    await Future.wait([for (final writer in _events) writer.flush()]);
  }

  bool _closed = false;

  Future<void> close() async {
    _closed = true;
    final writers = List.of(_events);
    _events.clear();
    await Future.wait([for (final writer in writers) writer.close()]);
    await drain();
  }
}
