import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/activity_battery.dart';

/// Sends an order to the session that runs in the participant window and
/// returns its answer, `{'ok': bool, 'message': String?}`.
typedef SessionCommandSender = Future<Map<String, dynamic>> Function(
  String command, [
  Map<String, dynamic> args,
]);

/// One logged attempt, as the monitor receives it in the snapshots.
class MonitorLog {
  const MonitorLog(this.map);

  final Map<String, dynamic> map;

  int get logIndex => (map['log_index'] as num?)?.toInt() ?? -1;
  int get activityIndex => (map['activity_index'] as num?)?.toInt() ?? 0;
  int get attempt => (map['attempt'] as num?)?.toInt() ?? 1;
  String get completion => map['completion']?.toString() ?? 'complete';
  String get endReason => map['end_reason']?.toString() ?? 'timer';
  double get durationSeconds => (map['duration_seconds'] as num?)?.toDouble() ?? 0;
  int? get rpe => (map['rpe'] as num?)?.toInt();
  int? get rpeBefore => (map['rpe_before'] as num?)?.toInt();
  int? get restingHr => (map['resting_hr_bpm'] as num?)?.toInt();
  String? get incident => map['incident']?.toString();
  String get kind => map['activity_kind']?.toString() ?? 'activity';
  bool get isSkipped => completion == 'skipped';
  bool get isPartial => completion == 'partial';

  Map<String, String> get fields => {
        for (final e in (map['redcap_fields'] as Map? ?? const {}).entries)
          e.key.toString(): e.value.toString(),
      };
}

/// What the Research Monitor knows about the session that runs in the
/// participant window: the protocol and participants (`session_info`), the
/// timer (`session_snapshot`, several times a second) and the folder where
/// it writes (`session_started`).
class MonitorSession extends ChangeNotifier {
  Map<String, dynamic> _info = const {};
  Map<String, dynamic> _snap = const {};
  ActivityBattery? _battery;
  String? _batteryJson;

  String? sessionDir;
  String? fileStamp;
  bool video = false;
  bool resumed = false;

  /// Summary of the saved session (`session_saved`).
  Map<String, dynamic>? summary;

  /// Folder of a cancelled session.
  String? cancelledDirectory;
  bool cancelled = false;

  DateTime? lastSnapshotAt;

  Map<String, dynamic> get info => _info;
  Map<String, dynamic> get snap => _snap;

  void setInfo(Map<dynamic, dynamic> value) {
    _info = Map<String, dynamic>.from(value);
    final battery = _info['battery'];
    final json = battery == null ? null : jsonEncode(battery);
    if (json != _batteryJson) {
      _batteryJson = json;
      try {
        _battery = battery is Map ? ActivityBattery.fromJson(Map<String, dynamic>.from(battery)) : null;
      } catch (e) {
        debugPrint('[MONITOR] Protocolo no válido en session_info: $e');
        _battery = null;
      }
    }
    resumed = _info['resumed'] == true;
    notifyListeners();
  }

  void setSnapshot(Map<dynamic, dynamic> value) {
    _snap = Map<String, dynamic>.from(value);
    lastSnapshotAt = DateTime.now();
    final dir = _snap['session_dir']?.toString();
    if (dir != null && dir.isNotEmpty) sessionDir = dir;
    notifyListeners();
  }

  void setStarted(Map<dynamic, dynamic> value) {
    sessionDir = value['session_dir']?.toString();
    fileStamp = value['file_stamp']?.toString();
    video = value['video'] == true;
    resumed = value['resumed'] == true;
    summary = null;
    cancelled = false;
    cancelledDirectory = null;
    notifyListeners();
  }

  void setSaved(Map<dynamic, dynamic> value) {
    summary = Map<String, dynamic>.from(value);
    notifyListeners();
  }

  void setCancelled(Map<dynamic, dynamic> value) {
    cancelled = true;
    cancelledDirectory = value['directory']?.toString();
    notifyListeners();
  }

  // ===========================================================================
  // Session
  // ===========================================================================

  ActivityBattery? get battery => _battery;

  /// `idle`, `running`, `paused`, `finished`, `finishing`, `saved` or
  /// `cancelled`.
  String get status => _snap['status']?.toString() ?? 'idle';

  bool get isIdle => status == 'idle';
  bool get isRunning => status == 'running';
  bool get isPaused => status == 'paused';
  bool get isClosing => const {'finished', 'finishing', 'saved', 'cancelled'}.contains(status);
  bool get isActive => isRunning || isPaused;

  String get participants => _info['participants']?.toString().replaceAll(';', ' + ') ?? '--';

  String get visit {
    final code = _info['visit']?.toString() ?? '';
    final match = RegExp(r'^D(\d+)$').firstMatch(code);
    return match == null ? code : 'Día ${match.group(1)}';
  }

  String? get operator {
    final text = _info['operator']?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  String? get study => _battery?.study;
  String? get protocolTitle => _battery?.title ?? _battery?.protocolId;
  bool get redcapConfigured => _info['redcap_configured'] == true;
  bool get voice => _snap['voice'] as bool? ?? (_info['settings'] as Map?)?['voice'] as bool? ?? true;

  Map<String, dynamic> get settings =>
      Map<String, dynamic>.from(_info['settings'] as Map? ?? const {});

  int get activityIndex => (_snap['activity_index'] as num?)?.toInt() ?? 1;
  int get activityCount => (_snap['activity_count'] as num?)?.toInt() ?? (_battery?.activities.length ?? 0);
  String get activityName => _snap['activity_name']?.toString() ?? 'Actividad $activityIndex';
  int get attempt => (_snap['attempt'] as num?)?.toInt() ?? 1;

  /// `static_prep`, `activity_main`, `static_post` or `transition_lap`.
  String get phase => _snap['phase']?.toString() ?? 'static_prep';

  double get remainingSeconds => (_snap['remaining_s'] as num?)?.toDouble() ?? 0;
  double? get plannedSeconds => (_snap['planned_s'] as num?)?.toDouble();
  int get elapsedPhaseSeconds => (_snap['elapsed_phase_s'] as num?)?.toInt() ?? 0;
  int get sessionElapsedSeconds => (_snap['session_elapsed_s'] as num?)?.toInt() ?? 0;
  int? get nextIndex => (_snap['next_index'] as num?)?.toInt();
  String? get nextName => _snap['next_name']?.toString();
  bool get protocolComplete => _snap['protocol_complete'] == true;
  bool get mainInProgress => _snap['main_in_progress'] == true;
  bool get syncAvailable => _snap['sync_available'] == true;
  String? get syncReason => _snap['sync_reason']?.toString();
  String get syncKind => _snap['sync_kind']?.toString() ?? 'clap';
  int get syncCount => (_snap['sync_count'] as num?)?.toInt() ?? 0;
  Map<String, dynamic>? get cue =>
      _snap['cue'] is Map ? Map<String, dynamic>.from(_snap['cue'] as Map) : null;
  String? get storeError => _snap['store_error']?.toString();
  String? get notice => _snap['notice']?.toString();
  int? get pendingRpeLog => (_snap['pending_rpe_log'] as num?)?.toInt();
  int? get rpeBeforeFor => (_snap['rpe_before_for'] as num?)?.toInt();

  Map<int, int> get rpeBefore => {
        for (final e in (_snap['rpe_before'] as Map? ?? const {}).entries)
          if (int.tryParse(e.key.toString()) != null && e.value is num)
            int.parse(e.key.toString()): (e.value as num).toInt(),
      };

  List<MonitorLog> get logs => [
        for (final l in _snap['logs'] as List? ?? const [])
          if (l is Map) MonitorLog(Map<String, dynamic>.from(l)),
      ];

  List<int> get notDone => [
        for (final i in _snap['not_done'] as List? ?? const [])
          if (i is num) i.toInt(),
      ];

  bool get isStillPhase => phase == 'static_prep' || phase == 'static_post';
  bool get isWait => phase == 'transition_lap';
  bool get isMain => phase == 'activity_main';

  BatteryActivity? activityAt(int index) => _battery?.activityAt(index);

  String nameOf(int index) => activityAt(index)?.name ?? 'Actividad $index';

  /// Last logged attempt of each activity (the one that counts).
  MonitorLog? lastLogOf(int index) {
    MonitorLog? last;
    for (final log in logs) {
      if (log.activityIndex == index) last = log;
    }
    return last;
  }

  MonitorLog? logAt(int logIndex) {
    for (final log in logs) {
      if (log.logIndex == logIndex) return log;
    }
    return null;
  }

  void clear() {
    _info = const {};
    _snap = const {};
    _battery = null;
    _batteryJson = null;
    sessionDir = null;
    fileStamp = null;
    video = false;
    resumed = false;
    summary = null;
    cancelled = false;
    cancelledDirectory = null;
    lastSnapshotAt = null;
    notifyListeners();
  }
}

/// `m:ss` (or `h:mm:ss`).
String formatClock(num seconds) {
  final total = seconds.isNegative ? 0 : seconds.ceil();
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}
