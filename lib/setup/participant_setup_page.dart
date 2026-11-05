import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../calibration/calibration_page.dart';
import '../calibration/calibration_store.dart';
import '../config/default_protocol_configuration.dart';
import '../models/protocol_configuration.dart';
import '../windows/window_messages.dart';
import 'device_guide.dart';
import 'live_connect_dialog.dart';
import '../models/activity_battery.dart';
import '../services/lab_redcap_service.dart';
import '../services/phone_records_import.dart';
import '../services/protocol_library.dart';
import '../services/redcap_connection.dart';
import '../services/redcap_resend.dart';
import '../session/session_controller.dart';
import '../session/session_store.dart';
import 'protocol_editor_page.dart';
import 'redcap_settings_dialog.dart';
import 'session_setup_card.dart';
import '../ui/app_theme.dart';

Color get _accent => Palette.current.accent;
Color get _card => Palette.current.surface;
Color get _field => Palette.current.panel;
Color get _warning => Palette.current.warn;

/// One participant of the session as typed in the start screen: ID, visit,
/// the serial of each sensor they wear and the folder of their files.
class ParticipantFieldGroup {
  final TextEditingController controller;
  String eventName;

  /// Serial number typed for each sensor of the protocol, by sensor ID.
  final Map<String, TextEditingController> serials = {};

  /// Participant ID whose remembered setup filled the serials.
  String? rememberedFor;

  ParticipantFieldGroup({
    required this.controller,
    this.eventName = 'da_0__visita_inici_arm_1',
  });

  String get id => controller.text.trim();

  TextEditingController serialOf(String sensorId, {String initial = ''}) =>
      serials.putIfAbsent(sensorId, () => TextEditingController(text: initial));

  /// Serial of the device taken home for the free-living days, by sensor ID
  /// (offline sensors only).
  final Map<String, TextEditingController> freeLivingSerials = {};

  TextEditingController freeLivingSerialOf(String sensorId, {String initial = ''}) =>
      freeLivingSerials.putIfAbsent(sensorId, () => TextEditingController(text: initial));

  String? freeLivingSerialFor(String sensorId) {
    final typed = freeLivingSerials[sensorId]?.text.trim() ?? '';
    return typed.isEmpty ? null : typed;
  }

  /// Devices the evaluator ticked as initialized in the waiting room:
  /// `lab:<sensorId>` and `free_living:<sensorId>`.
  final Set<String> initialized = {};

  void dispose() {
    controller.dispose();
    for (final c in [...serials.values, ...freeLivingSerials.values]) {
      c.dispose();
    }
  }
}

// ==========================================
// 1. HOME (LOGIN) SCREEN
// ==========================================
/// Keys of this computer's settings.
class SetupPrefs {
  static const dataRoot = 'lpt_data_root';

  /// Evaluators of the last session, as a list.
  static const operators = 'lpt_operators';

  /// The only evaluator, as saved before 1.4.0 (read once, then removed).
  static const operator = 'lpt_operator';
  static const activeSession = 'lpt_active_session_dir';

  /// Clap or jump, as last chosen on this computer.
  static const syncKind = 'lpt_sync_kind';

  /// Folder of the healthy_tracker phones' files (the study's Google Drive
  /// folder on this computer), as last chosen.
  static const phoneRecordsFolder = 'lpt_phone_records_folder';

  /// Session-recovery keys of the old timer (before the session folder).
  static const legacy = [
    'saved_participants_list',
    'saved_completed_activities',
    'saved_session_start',
    'saved_current_activity',
    'saved_session_id',
    'saved_sync_windows',
    'saved_battery',
  ];

  /// Remembers the folder of the running session (null when it ends) so a
  /// crash or a closed window can be resumed at the next start.
  static Future<void> rememberActiveSession(String? directory) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (directory == null) {
        await prefs.remove(activeSession);
      } else {
        await prefs.setString(activeSession, directory);
      }
    } catch (e) {
      debugPrint('[SETUP] No se pudo recordar la sesión activa: $e');
    }
  }

  /// `Documentos\lab_protocol_timer_sesiones`.
  static Future<String> defaultDataRoot() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      return '${docs.path}${Platform.pathSeparator}lab_protocol_timer_sesiones';
    } catch (_) {
      return '${Directory.current.path}${Platform.pathSeparator}lab_protocol_timer_sesiones';
    }
  }
}

/// Builds the session the setup asks for (the real one opens the monitor
/// and the timer; tests capture it).
typedef SessionStarter = Future<void> Function(SessionController controller);

/// The start screen, in three steps: the participants (ID and visit), the
/// protocol with the sensors and serials of each participant, and the
/// folder of each participant. The second and third steps wait until every
/// participant has an ID.
class ParticipantSetupPage extends StatefulWidget {
  const ParticipantSetupPage({
    super.key,
    required this.onStart,
    required this.monitor,
    required this.audioFactory,
    this.onPrepare,
    this.checkUnfinished = true,
  });

  final SessionStarter onStart;

  /// Opens (or shows) the Research Monitor with the devices of the session,
  /// so they can be connected from the waiting room.
  /// [fresh] the first time (a new evaluation); false when the evaluator
  /// shows it again, so the Polar and cameras stay linked.
  final Future<void> Function(ProtocolConfiguration configuration, bool fresh)? onPrepare;
  final MonitorLink monitor;
  final SessionAudio Function() audioFactory;

  /// Look for sessions left open (crash, window closed).
  final bool checkUnfinished;

  @override
  State<ParticipantSetupPage> createState() => _ParticipantSetupPageState();
}

class _ParticipantSetupPageState extends State<ParticipantSetupPage> {
  final _formKey = GlobalKey<FormState>();
  final List<ParticipantFieldGroup> _participants = [];
  final _activityController = TextEditingController(text: '1');

  /// One field per evaluator; there are at least [_minOperatorFields].
  final List<TextEditingController> _operatorControllers = [
    for (var i = 0; i < _minOperatorFields; i++) TextEditingController(),
  ];

  /// Fields shown from the start: sessions have two evaluators or more.
  static const _minOperatorFields = 2;
  String? _dataRoot;

  /// Calibration of the sensors done today under the data folder.
  List<CalibrationRecord> _calibrations = const [];
  bool _starting = false;

  /// After «Preparar sesión»: serial numbers, Polar and camera, calibration.
  bool _waitingRoom = false;

  /// The Polar of the session as the monitor last told (waiting room).
  List<LiveDeviceState>? _live;
  Timer? _livePoll;

  /// The monitor was opened for this session: showing it again keeps its
  /// links.
  bool _monitorOpened = false;
  bool _sendingSaved = false;

  /// While the phones' files go to REDCap: which one (e.g. «2 de 5»).
  String? _sendingPhone;

  /// Protocol and sensors of the session (null: numbered activities).
  ActivityBattery? _battery;

  /// Sync cue chosen on this computer; null keeps the protocol's own. It is
  /// not part of the protocol, so it stays from one participant to the next.
  SyncKind? _syncKind;

  /// The protocol as the session will run it, with the chosen sync cue.
  ActivityBattery? get _sessionBattery {
    final battery = _battery;
    final kind = _syncKind;
    if (battery == null || kind == null) return battery;
    return battery.copyWith(sync: battery.sync.copyWith(kind: kind));
  }

  List<ActivityBattery> _builtInProtocols = [];
  List<ActivityBattery> _customProtocols = [];
  Map<String, RememberedSetup> _rememberedSetups = {};
  bool _loadingProtocols = true;

  /// What was loaded automatically for the first participant.
  String? _setupNote;

  static const Map<String, String> _defaultEvents = {
    'da_0__visita_inici_arm_1': 'Visita Inicial (Día 0)',
    'da_8__visita_final_arm_1': 'Visita Final (Día 8)',
  };

  /// Visits to choose from: the events of the REDCap project when they are
  /// known, otherwise those of RUN4HEALTH.
  Map<String, String> get _eventOptions {
    final events = RedcapConnection.events;
    return events.isEmpty ? _defaultEvents : events;
  }

  /// Every participant has an ID: the protocol and the folders can be set.
  bool get _participantsReady => _participants.isNotEmpty && _participants.every((p) => p.id.isNotEmpty);

  /// The sensors each participant wears (the cameras are the session's).
  List<SessionSensor> get _layoutSensors => [
        for (final s in _battery?.sensors ?? const <SessionSensor>[])
          if (s.connection != 'video') s,
      ];

  @override
  void initState() {
    super.initState();

    _addParticipantField(); // Default - 1 participant
    _loadProtocols();
    _loadPrefs();
    RedcapConnection.changes.addListener(_onRedcapChanged);
  }

  /// Another REDCap project, or its events: every participant keeps a visit
  /// of the list.
  void _onRedcapChanged() {
    if (!mounted) return;
    final options = _eventOptions;
    setState(() {});
    for (final p in _participants) {
      if (!options.containsKey(p.eventName)) _onMomentChanged(p, options.keys.first);
    }
  }

  Future<void> _openRedcapSettings() => showRedcapSettingsDialog(context);

  Future<void> _loadPrefs() async {
    String? root;
    List<String>? operators;
    String? syncKind;
    try {
      final prefs = await SharedPreferences.getInstance();
      root = prefs.getString(SetupPrefs.dataRoot);
      operators = prefs.getStringList(SetupPrefs.operators);
      final old = prefs.getString(SetupPrefs.operator);
      if (operators == null && old != null && old.trim().isNotEmpty) operators = [old.trim()];
      await prefs.remove(SetupPrefs.operator);
      syncKind = prefs.getString(SetupPrefs.syncKind);
      for (final key in SetupPrefs.legacy) {
        await prefs.remove(key);
      }
    } catch (e) {
      debugPrint('[SETUP] No se pudieron leer los ajustes: $e');
    }
    root ??= await SetupPrefs.defaultDataRoot();
    if (!mounted) return;
    setState(() {
      _dataRoot = root;
      if (operators != null && operators.isNotEmpty && _operatorNames.isEmpty) _setOperators(operators);
      if (syncKind != null && _syncKind == null) _syncKind = SyncKind.parse(syncKind);
    });
    await _loadCalibration();
    if (widget.checkUnfinished) await _checkUnfinishedSessions();
  }

  Future<void> _chooseDataRoot() async {
    final chosen = await getDirectoryPath(
      confirmButtonText: 'Usar esta carpeta',
      initialDirectory: _dataRoot,
    );
    if (chosen == null || !mounted) return;
    setState(() {
      _dataRoot = chosen;
      _calibrations = const [];
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(SetupPrefs.dataRoot, chosen);
    } catch (_) {}
    await _loadCalibration();
  }

  /// Looks for today's calibrations under the data folder.
  Future<void> _loadCalibration() async {
    final root = _dataRoot;
    if (root == null) return;
    var found = const <CalibrationRecord>[];
    try {
      found = await CalibrationStore.recentBefore(root, DateTime.now());
    } catch (_) {}
    if (!mounted || root != _dataRoot) return;
    setState(() => _calibrations = found);
  }

  /// Devices proposed for the dodecahedron: the offline sensors of the
  /// session with the serials typed so far (each one once), or the
  /// protocol's offline sensors without serial when none is typed yet.
  List<CalibrationDevice> _devicesToCalibrate() {
    final offline = [
      for (final s in _layoutSensors)
        if (s.connection == 'offline' && s.type != 'other') s,
    ];
    final typed = <CalibrationDevice>{
      for (final group in _participants)
        for (final s in offline) ...[
          if (s.inLab)
            if (_serialFor(group, s) case final serial?) CalibrationDevice(s.type, serial),
          if (s.inFreeLiving)
            if (group.freeLivingSerialFor(s.sensorId) case final serial?) CalibrationDevice(s.type, serial),
        ],
    };
    if (typed.isNotEmpty) return typed.toList();
    return [
      for (final s in offline) ...[
        if (s.inLab) CalibrationDevice(s.type, ''),
        if (s.inFreeLiving) CalibrationDevice(s.type, ''),
      ],
    ];
  }

  /// Offline sensors of [entries] without a calibration of today, as
  /// «P01: AX6 · Pie izquierdo (1234)».
  List<String> _uncalibrated(List<ParticipantEntry> entries, List<CalibrationRecord> records) => [
        for (final p in entries)
          for (final s in p.sensors)
            if (s.connection == 'offline' && s.type != 'other') ...[
              if (s.inLab && CalibrationStore.forDevice(records, s.type, s.serial) == null)
                '${p.participantId}: ${s.displayName}${s.hasSerial ? ' (${s.serial!.trim()})' : ' (sin número de serie)'}',
              if (s.inFreeLiving && CalibrationStore.forDevice(records, s.type, s.freeLivingSerial) == null)
                '${p.participantId}: ${s.displayName}, vida libre'
                    '${s.hasFreeLivingSerial ? ' (${s.freeLivingSerial!.trim()})' : ' (sin número de serie)'}',
            ],
      ];

  Future<void> _calibrate() async {
    final root = _dataRoot ?? await SetupPrefs.defaultDataRoot();
    try {
      await Directory(root).create(recursive: true);
    } catch (_) {}
    if (!mounted) return;
    final record = await Navigator.of(context).push<CalibrationRecord>(
      MaterialPageRoute(
        builder: (_) => CalibrationPage(
          dataRoot: root,
          audio: widget.audioFactory(),
          initialDevices: _devicesToCalibrate(),
        ),
      ),
    );
    if (!mounted) return;
    if (record != null && _dataRoot == null) setState(() => _dataRoot = root);
    await _loadCalibration();
  }

  /// Where the files of [group] go: `<root>/<study>_<ID>/<visit>` under
  /// the parent folder.
  String _folderOf(ParticipantFieldGroup group) {
    final root = _dataRoot ?? '...';
    final id = group.id.isEmpty ? '<ID>' : group.id;
    return SessionStore.defaultFolder(
      root,
      _battery?.study,
      ParticipantEntry(participantId: id, redcapEventName: group.eventName),
    );
  }

  List<ActivityBattery> get _allProtocols => [..._builtInProtocols, ..._customProtocols];

  ActivityBattery? _protocolById(String? id) {
    for (final p in _allProtocols) {
      if (p.protocolId == id) return p;
    }
    return null;
  }

  bool get _batteryModified {
    final saved = _protocolById(_battery?.protocolId);
    return saved != null && jsonEncode(saved.toJson()) != jsonEncode(_battery!.toJson());
  }

  Future<void> _loadProtocols() async {
    try {
      final builtIns = await ProtocolLibrary.loadBuiltIns();
      final custom = await ProtocolLibrary.loadCustom();
      final remembered = await ProtocolLibrary.loadRemembered();
      final lastId = await ProtocolLibrary.lastProtocolId();
      if (!mounted) return;
      setState(() {
        _builtInProtocols = builtIns;
        _customProtocols = custom;
        _rememberedSetups = remembered;
        _loadingProtocols = false;
        final initial = _protocolById(lastId) ?? builtIns.first;
        _battery = ProtocolLibrary.forMoment(
              initial,
              _participants.first.eventName,
              _allProtocols,
            ) ??
            initial;
      });
      for (final group in _participants) {
        _onParticipantIdChanged(group);
      }
    } catch (e) {
      debugPrint('[SETUP] No se pudieron cargar los protocolos: $e');
      if (mounted) setState(() => _loadingProtocols = false);
    }
  }

  // ===========================================================================
  // Serials of each participant
  // ===========================================================================

  /// The serial field of [sensor] for [group]. A new field starts with the
  /// participant's remembered serial for that sensor or, when they are the
  /// only participant, with the serial of the protocol's sensor list.
  TextEditingController _serialController(ParticipantFieldGroup group, SessionSensor sensor) {
    final existing = group.serials[sensor.sensorId];
    if (existing != null) return existing;
    final remembered = _rememberedSerial(group.id, sensor);
    final initial = remembered ?? (_participants.length == 1 && sensor.hasSerial ? sensor.serial!.trim() : '');
    return group.serialOf(sensor.sensorId, initial: initial);
  }

  /// The free-living serial field of [sensor] for [group], starting with
  /// the participant's remembered one.
  TextEditingController _freeLivingSerialController(ParticipantFieldGroup group, SessionSensor sensor) {
    final existing = group.freeLivingSerials[sensor.sensorId];
    if (existing != null) return existing;
    String initial = '';
    for (final old in _rememberedSetups[group.id]?.battery.sensors ?? const <SessionSensor>[]) {
      if (old.sensorId == sensor.sensorId && old.type == sensor.type && old.hasFreeLivingSerial) {
        initial = old.freeLivingSerial!.trim();
      }
    }
    return group.freeLivingSerialOf(sensor.sensorId, initial: initial);
  }

  String? _rememberedSerial(String participantId, SessionSensor sensor) {
    final remembered = _rememberedSetups[participantId];
    if (remembered == null) return null;
    for (final old in remembered.battery.sensors) {
      if (old.sensorId == sensor.sensorId && old.type == sensor.type && old.hasSerial) {
        return old.serial!.trim();
      }
    }
    return null;
  }

  /// The serial typed for [sensor] by [group]; without one, the serial of
  /// the protocol's sensor when they are the only participant.
  String? _serialFor(ParticipantFieldGroup group, SessionSensor sensor) {
    final typed = group.serials[sensor.sensorId]?.text.trim() ?? '';
    if (typed.isNotEmpty) return typed;
    if (_participants.length == 1 && sensor.hasSerial) return sensor.serial!.trim();
    return null;
  }

  /// Devices of [group] without a serial number: the laboratory one of
  /// each laboratory sensor and the free-living one of each free-living
  /// sensor, as sensor IDs (`ax6_shoe_l (vida libre)`).
  List<String> _missingSerials(ParticipantFieldGroup group) => [
        for (final sensor in _layoutSensors) ...[
          if (sensor.inLab && _serialFor(group, sensor) == null) sensor.sensorId,
          if (sensor.inFreeLiving && group.freeLivingSerialFor(sensor.sensorId) == null)
            '${sensor.sensorId} (vida libre)',
        ],
      ];

  /// Fills the serial fields of [group] from a remembered setup.
  void _fillSerials(ParticipantFieldGroup group, List<SessionSensor> remembered) {
    for (final sensor in _layoutSensors) {
      for (final old in remembered) {
        if (old.sensorId == sensor.sensorId && old.type == sensor.type) {
          group.serialOf(sensor.sensorId).text = old.hasSerial ? old.serial!.trim() : '';
          group.freeLivingSerialOf(sensor.sensorId).text = old.hasFreeLivingSerial ? old.freeLivingSerial!.trim() : '';
        }
      }
    }
  }

  /// The protocol changed: the only participant's empty fields (or those
  /// still equal to the previous layout) take the serials of the new one.
  void _syncLayoutSerials(ActivityBattery? previous, ActivityBattery? next) {
    if (_participants.length != 1 || next == null) return;
    final group = _participants.single;
    final before = {for (final s in previous?.sensors ?? const <SessionSensor>[]) s.sensorId: s};
    for (final sensor in next.sensors) {
      if (sensor.connection == 'video' || !sensor.hasSerial) continue;
      final field = group.serials[sensor.sensorId];
      if (field == null) continue;
      final text = field.text.trim();
      final old = before[sensor.sensorId];
      if (text.isEmpty || (old != null && old.hasSerial && text == old.serial!.trim())) {
        field.text = sensor.serial!.trim();
      }
    }
  }

  void _setBattery(ActivityBattery? next) {
    final previous = _battery;
    _battery = next;
    _syncLayoutSerials(previous, next);
  }

  /// The ID of [group] changed: a participant who already had a session on
  /// this computer gets their serials back (the first one also brings back
  /// the protocol of that session for this visit).
  void _onParticipantIdChanged(ParticipantFieldGroup group) {
    if (!mounted) return;
    setState(() {});
    if (_loadingProtocols || !_participants.contains(group)) return;
    final id = group.id;
    if (id == group.rememberedFor) return;
    final isFirst = group == _participants.first;

    final remembered = _rememberedSetups[id];
    if (remembered == null) {
      if (group.rememberedFor != null) {
        // Another participant: empty serials and, for the first one, back
        // to the plain protocol of this visit.
        setState(() {
          group.rememberedFor = null;
          for (final field in group.serials.values) {
            field.clear();
          }
          if (isFirst) {
            _setupNote = null;
            final plain = _protocolById(_battery?.protocolId);
            if (plain != null) _setBattery(plain);
          }
        });
      }
      return;
    }

    final visit = _eventOptions[remembered.eventName] ?? remembered.eventName;
    final when = remembered.savedAt.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');

    setState(() {
      group.rememberedFor = id;
      if (isFirst) {
        final saved = _protocolById(remembered.battery.protocolId) ?? remembered.battery;
        final protocol = ProtocolLibrary.forMoment(saved, group.eventName, _allProtocols) ?? saved;
        _setBattery(ProtocolLibrary.applyRemembered(protocol, remembered));
        _setupNote = 'Sensores y números de serie de la sesión anterior de $id '
            '($visit, ${two(when.day)}/${two(when.month)} ${two(when.hour)}:${two(when.minute)}).';
      }
      _fillSerials(group, remembered.battery.sensors);
    });
  }

  void _onMomentChanged(ParticipantFieldGroup item, String moment) {
    setState(() => item.eventName = moment);
    if (item != _participants.first || _battery == null) return;

    final next = ProtocolLibrary.forMoment(_battery!, moment, _allProtocols);
    if (next == null || next.protocolId == _battery!.protocolId) return;
    final remembered = _rememberedSetups[item.rememberedFor];
    setState(() {
      _setBattery(remembered != null
          ? ProtocolLibrary.applyRemembered(next, remembered)
          : ProtocolLibrary.carrySensorDetails(next, _battery!.sensors));
    });
  }

  void _selectProtocol(String? id) {
    if (id == _battery?.protocolId && !_batteryModified) return;
    final selected = _protocolById(id);
    setState(() {
      _setupNote = null;
      _setBattery(selected == null
          ? (id == null ? null : _battery)
          : ProtocolLibrary.carrySensorDetails(
              selected,
              _battery?.sensors ?? const [],
            ));
    });
  }

  Future<void> _chooseSyncKind(SyncKind kind) async {
    setState(() => _syncKind = kind);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(SetupPrefs.syncKind, kind.name);
    } catch (e) {
      debugPrint('[SETUP] No se pudo guardar la sincronización: $e');
    }
  }

  Future<void> _editProtocol() async {
    final battery = _battery;
    if (battery == null) return;
    final edited = await Navigator.of(context).push<ActivityBattery>(
      MaterialPageRoute(
        builder: (_) => ProtocolEditorPage(
          initial: battery,
          onSaved: (saved) async {
            final custom = await ProtocolLibrary.loadCustom();
            if (mounted) setState(() => _customProtocols = custom);
          },
        ),
      ),
    );
    if (edited == null || !mounted) return;
    setState(() => _setBattery(edited));
  }

  /// Sends to REDCap a saved session whose records did not get there (no
  /// token on this computer, the app was closed, there was no network or
  /// the REDCap project needed a change).
  Future<void> _sendSavedSession() async {
    if (!RedcapConnection.isConfigured) {
      await _openRedcapSettings();
      if (!mounted || !RedcapConnection.isConfigured) return;
    }
    final chosen = await getDirectoryPath(
      confirmButtonText: 'Enviar esta sesión',
      initialDirectory: _dataRoot,
    );
    if (chosen == null || !mounted) return;
    setState(() => _sendingSaved = true);
    final error = await SavedSessionRedcap.send(Directory(chosen));
    if (!mounted) return;
    setState(() => _sendingSaved = false);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _card,
        title: Text(error == null ? 'Sesión enviada a REDCap' : 'No se pudo enviar'),
        content: SelectableText(error ?? 'REDCap ya tiene los registros de $chosen.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cerrar')),
        ],
      ),
    );
  }

  /// Sends to REDCap the records healthy_tracker phones left in a folder:
  /// the study's Google Drive folder, synced to this computer, or a file
  /// copied from a phone by cable. Rows REDCap already has are skipped.
  Future<void> _sendPhoneRecords() async {
    if (!RedcapConnection.isConfigured) {
      await _openRedcapSettings();
      if (!mounted || !RedcapConnection.isConfigured) return;
    }
    String? lastFolder;
    try {
      lastFolder = (await SharedPreferences.getInstance()).getString(SetupPrefs.phoneRecordsFolder);
    } catch (_) {}
    final chosen = await getDirectoryPath(
      confirmButtonText: 'Enviar los registros de esta carpeta',
      initialDirectory: lastFolder ?? _dataRoot,
    );
    if (chosen == null || !mounted) return;
    try {
      await (await SharedPreferences.getInstance()).setString(SetupPrefs.phoneRecordsFolder, chosen);
    } catch (_) {}
    setState(() => _sendingPhone = '');
    // Whether the project has events decides how the rows go.
    await RedcapConnection.refreshProject();
    final results = await PhoneRecordsImport().sendFolder(
      Directory(chosen),
      onFile: (index, total, _) {
        if (mounted) setState(() => _sendingPhone = '${index + 1} de $total');
      },
    );
    if (!mounted) return;
    setState(() => _sendingPhone = null);
    final summary = PhoneRecordsImport.describe(results, chosen);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _card,
        title: Text(summary.title),
        content: SizedBox(
          width: 640,
          child: SingleChildScrollView(child: SelectableText(summary.message)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cerrar')),
        ],
      ),
    );
  }

  Future<void> _deleteCustomProtocol() async {
    final battery = _battery;
    if (battery == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _card,
        title: const Text('Borrar protocolo guardado'),
        content: Text(
          '¿Borrar «${battery.displayName}» de este ordenador? '
          'Las sesiones ya hechas no cambian.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: context.pal.bad),
            child: const Text('Borrar'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ProtocolLibrary.deleteCustom(battery.protocolId);
    final custom = await ProtocolLibrary.loadCustom();
    if (!mounted) return;
    setState(() {
      _customProtocols = custom;
      _setBattery(_builtInProtocols.isEmpty ? null : _builtInProtocols.first);
    });
  }

  void _addParticipantField([String initialId = '', String? initialEvent]) {
    final group = ParticipantFieldGroup(
      controller: TextEditingController(text: initialId),
      eventName: initialEvent ?? _eventOptions.keys.first,
    );
    group.controller.addListener(() => _onParticipantIdChanged(group));
    setState(() => _participants.add(group));
  }

  void _removeParticipantField(int index) {
    if (_participants.length > 1) {
      setState(() {
        _participants.removeAt(index).dispose();
      });
    }
  }

  @override
  void dispose() {
    _stopLivePoll();
    RedcapConnection.changes.removeListener(_onRedcapChanged);
    for (final p in _participants) {
      p.dispose();
    }
    _activityController.dispose();
    for (final c in _operatorControllers) {
      c.dispose();
    }
    super.dispose();
  }

  /// Offers to resume a session left open by a crash or a closed window.
  Future<void> _checkUnfinishedSessions() async {
    final found = <String, UnfinishedSession>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      final active = prefs.getString(SetupPrefs.activeSession);
      if (active != null) {
        final session = await UnfinishedSession.find(active);
        if (session != null) {
          found[session.directory.path] = session;
        } else {
          await prefs.remove(SetupPrefs.activeSession);
        }
      }
    } catch (e) {
      debugPrint('[SETUP] No se pudo leer la sesión activa: $e');
    }
    final root = _dataRoot;
    if (root != null) {
      for (final session in await UnfinishedSession.scan(root)) {
        found.putIfAbsent(session.directory.path, () => session);
      }
    }
    if (found.isEmpty || !mounted) return;
    final sessions = found.values.toList()
      ..sort((a, b) => (b.savedAt ?? DateTime(0)).compareTo(a.savedAt ?? DateTime(0)));
    final session = sessions.first;

    final names = session.participants.map((p) => p.participantId).join(', ');
    final saved = session.savedAt?.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    final when = saved == null
        ? ''
        : ' (guardada el ${two(saved.day)}/${two(saved.month)} a las ${two(saved.hour)}:${two(saved.minute)})';
    final total = session.battery?.activities.length;

    final action = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: _card,
        title: Row(
          children: [
            Icon(Icons.history_rounded, color: context.pal.warn),
            const SizedBox(width: 10),
            const Text('Sesión sin terminar'),
          ],
        ),
        content: SizedBox(
          width: 520,
          child: Text(
            'Participante $names$when.\n'
            '${session.loggedActivities}${total == null ? '' : ' de $total'} actividades registradas.\n\n'
            'Al reanudarla se abre en pausa en la actividad en la que estaba; la actividad '
            'que se cortó queda como parcial y se puede repetir.\n\n'
            '${session.directory.path}'
            '${sessions.length > 1 ? '\n\nHay ${sessions.length - 1} sesión(es) más sin terminar en la carpeta de datos.' : ''}',
            style: TextStyle(color: context.pal.on70, height: 1.4),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop('later'),
            child: const Text('Ahora no'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: context.pal.bad),
            onPressed: () => Navigator.of(context).pop('cancel'),
            child: const Text('Cancelar esa sesión'),
          ),
          FilledButton.icon(
            autofocus: true,
            onPressed: () => Navigator.of(context).pop('resume'),
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Reanudar'),
          ),
        ],
      ),
    );
    if (!mounted || action == null || action == 'later') return;

    final controller = SessionController.resume(
      session,
      audio: action == 'resume' ? widget.audioFactory() : SilentAudio(),
      monitor: action == 'resume' ? widget.monitor : NoMonitor(),
      onActiveSessionChanged: SetupPrefs.rememberActiveSession,
    );
    if (action == 'cancel') {
      final ok = await _confirm(
        'Cancelar la sesión sin terminar',
        'No se envía nada a REDCap y la carpeta queda marcada como cancelada '
            '(los archivos se conservan).',
        'Cancelar la sesión',
      );
      if (!ok) {
        controller.dispose();
        return;
      }
      await controller.cancel(reason: 'Cancelada al reabrir la aplicación');
      controller.dispose();
      await SetupPrefs.rememberActiveSession(null);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sesión cancelada; la carpeta se ha conservado.')),
        );
      }
      return;
    }
    await widget.onStart(controller);
  }

  Future<bool> _confirm(String title, String message, String confirm) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _card,
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Volver')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: context.pal.bad),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirm),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _loadBattery() async {
    const typeGroup = XTypeGroup(
      label: 'Protocolo JSON',
      extensions: ['json'],
    );

    final file = await openFile(acceptedTypeGroups: [typeGroup]);
    if (file == null) return;

    try {
      final battery = ActivityBattery.parse(await file.readAsString());
      if (!mounted) return;
      setState(() {
        _setBattery(battery);
        _setupNote = 'Importado de ${file.name}. Para tenerlo en la lista, '
            'ábrelo en «Editar» y guárdalo como protocolo.';
      });
    } on FormatException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Protocolo no válido: ${e.message}')),
      );
    }
  }

  /// The participants as the session gets them: ID, visit, their sensors
  /// with the serials typed for them and the folder chosen for them.
  List<ParticipantEntry> _entries() {
    final layout = _layoutSensors;
    return [
      for (final group in _participants)
        ParticipantEntry(
          participantId: group.id,
          redcapEventName: group.eventName,
          sensors: [
            for (final sensor in layout)
              (switch (sensor.inLab ? _serialFor(group, sensor) : null) {
                final serial? => sensor.copyWith(serial: serial),
                null => sensor.copyWith(clearSerial: true),
              })
                  .copyWith(
                freeLivingSerial: group.freeLivingSerialFor(sensor.sensorId),
                clearFreeLivingSerial: group.freeLivingSerialFor(sensor.sensorId) == null,
                initialized: sensor.inLab && group.initialized.contains('lab:${sensor.sensorId}'),
                freeLivingInitialized:
                    sensor.inFreeLiving && group.initialized.contains('free_living:${sensor.sensorId}'),
              ),
          ],
        ),
    ];
  }

  /// From the session data to the waiting room, where a second evaluator
  /// gets the sensors ready while the participant fills the questionnaires.
  Future<void> _prepare() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (!_participantsReady) return;
    setState(() => _waitingRoom = true);
    await _loadCalibration();
    await _openMonitor();
    _startLivePoll();
  }

  Future<void> _openMonitor() async {
    final open = widget.onPrepare;
    if (open == null) return;
    try {
      await open(protocolConfigurationFor(_sessionBattery, _entries()), !_monitorOpened);
      _monitorOpened = true;
    } catch (e) {
      debugPrint('[SETUP] No se pudo abrir el Research Monitor: $e');
    }
  }

  void _leaveWaitingRoom() {
    _stopLivePoll();
    setState(() {
      _waitingRoom = false;
      _live = null;
    });
  }

  Future<void> _submitAndStart() async {
    if (!_waitingRoom) {
      await _prepare();
      return;
    }
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    if (!_participantsReady) return;

    final entries = _entries();
    final activity = int.tryParse(_activityController.text.trim()) ?? 1;

    final notReady = [
      for (final group in _participants)
        if (_uninitialized(group) case final devices when devices.isNotEmpty) '${group.id}: ${devices.join(', ')}',
    ];
    if (notReady.isNotEmpty) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: _card,
          title: const Text('Dispositivos sin marcar'),
          content: Text(
            'Sin marcar como inicializados (o Polar sin conectar):\n${notReady.join('\n')}\n\n¿Pasar a la sesión igualmente?',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Volver')),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Seguir')),
          ],
        ),
      );
      if (proceed != true || !mounted) return;
    }

    final root = _dataRoot ?? await SetupPrefs.defaultDataRoot();
    final calibrations = await CalibrationStore.recentBefore(root, DateTime.now());
    if (!mounted) return;
    final uncalibrated = _uncalibrated(entries, calibrations);
    if (calibrations.isEmpty || uncalibrated.isNotEmpty) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: _card,
          title: const Text('Sensores sin calibrar'),
          content: Text(
            '¿Seguro que quieres empezar la sesión sin haber calibrado los sensores?\n\n'
            '${calibrations.isEmpty ? 'No hay ninguna calibración de hoy en la carpeta de la sesión.' : 'Sin calibración de hoy:\n${uncalibrated.join('\n')}'}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Volver'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Empezar sin calibrar'),
            ),
          ],
        ),
      );
      if (proceed != true || !mounted) return;
    }

    final battery = _sessionBattery;
    if (battery != null) {
      final missing = [
        for (final group in _participants)
          if (_missingSerials(group) case final sensors when sensors.isNotEmpty) '${group.id}: ${sensors.join(', ')}',
      ];
      if (missing.isNotEmpty) {
        final proceed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: _card,
            title: const Text('Faltan números de serie'),
            content: Text(
              'Sin número de serie:\n${missing.join('\n')}\n\n'
              'Se escriben aquí, en la sala de espera, junto a cada participante. '
              '¿Empezar igualmente?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Volver'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Empezar'),
              ),
            ],
          ),
        );
        if (proceed != true) return;
      }

      // The closing visit of these participants starts from this setup
      // (the sync cue is this computer's choice, not part of it).
      await ProtocolLibrary.remember(entries, _battery ?? battery);
    }

    if (!mounted) return;

    try {
      await Directory(root).create(recursive: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: context.pal.bad,
          content: Text('No se puede usar la carpeta de datos $root: $e'),
        ),
      );
      return;
    }
    final operators = _operatorNames;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(SetupPrefs.dataRoot, root);
      await prefs.setStringList(SetupPrefs.operators, operators);
    } catch (_) {}

    final controller = SessionController(
      participants: entries,
      battery: battery,
      dataRoot: root,
      calibrations: calibrations,
      // A protocol can run its activities one after another (lap_mode false).
      settings: SessionSettings(lapMode: battery?.lapMode ?? true),
      operators: operators,
      startIndex: activity,
      audio: widget.audioFactory(),
      monitor: widget.monitor,
      onActiveSessionChanged: SetupPrefs.rememberActiveSession,
    );
    if (!mounted) {
      controller.dispose();
      return;
    }
    setState(() => _starting = true);
    _stopLivePoll();
    try {
      await widget.onStart(controller);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  /// Where the sessions go besides their folder: REDCap, if there is a token.
  /// The names typed in the evaluator fields, without blanks or repeats.
  List<String> get _operatorNames => SessionController.cleanOperators([for (final c in _operatorControllers) c.text]);

  /// Fills the evaluator fields with [names] (the last session's).
  void _setOperators(List<String> names) {
    while (_operatorControllers.length < names.length) {
      _operatorControllers.add(TextEditingController());
    }
    for (var i = 0; i < _operatorControllers.length; i++) {
      _operatorControllers[i].text = i < names.length ? names[i] : '';
    }
  }

  void _addOperator() => setState(() => _operatorControllers.add(TextEditingController()));

  void _removeOperator(int index) {
    if (_operatorControllers.length <= _minOperatorFields) {
      _operatorControllers[index].clear();
      return;
    }
    setState(() => _operatorControllers.removeAt(index).dispose());
  }

  /// One field per evaluator (two at least) and a button to add another.
  Widget _operatorsCard() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < _operatorControllers.length; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          TextFormField(
            key: ValueKey('operator_field_$i'),
            controller: _operatorControllers[i],
            style: TextStyle(color: context.pal.on, fontWeight: FontWeight.w700, fontSize: 15),
            decoration: _decoration(
              label: 'EVALUADOR/A ${i + 1}',
              hint: i == 0 ? 'Nombre o iniciales (van a REDCap y al manifiesto)' : 'Nombre o iniciales',
              icon: Icons.badge_rounded,
              fill: _card,
              radius: 16,
            ).copyWith(
              suffixIcon: _operatorControllers.length > _minOperatorFields
                  ? IconButton(
                      tooltip: 'Quitar evaluador/a',
                      icon: Icon(Icons.close_rounded, color: context.pal.on54),
                      onPressed: () => _removeOperator(i),
                    )
                  : null,
            ),
          ),
        ],
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('add_operator'),
            onPressed: _addOperator,
            style: TextButton.styleFrom(foregroundColor: context.pal.on70),
            icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
            label: const Text('Añadir evaluador/a'),
          ),
        ),
      ],
    );
  }

  Widget _redcapCard() {
    final configured = RedcapConnection.isConfigured;
    final title = RedcapConnection.project?.title ?? '';
    final status = !configured
        ? 'Sin conexión: cada sesión se guarda solo en su carpeta y se puede enviar después.'
        : '${title.isEmpty ? 'Token ${RedcapConnection.masked(RedcapConnection.token)}' : 'Proyecto «$title»'}'
            '${RedcapConnection.tokenBuiltIn ? ' (token de esta versión de la app)' : ''} · ${RedcapConnection.url}';
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(
            configured ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
            color: configured ? context.pal.accent : context.pal.on38,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'REDCAP (OPCIONAL)',
                  style: TextStyle(color: context.pal.on60, fontSize: 12),
                ),
                const SizedBox(height: 2),
                Text(
                  status,
                  style: TextStyle(color: context.pal.on, fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: _openRedcapSettings,
            child: Text(configured ? 'Cambiar' : 'Conectar'),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // Screen
  // ===========================================================================

  InputDecoration _decoration({
    required String label,
    String? hint,
    IconData? icon,
    Color? fill,
    double radius = 12,
  }) =>
      InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: context.pal.on60, fontSize: 12),
        hintText: hint,
        hintStyle: TextStyle(color: context.pal.on24),
        prefixIcon: icon == null ? null : Icon(icon, color: _accent, size: 20),
        filled: true,
        fillColor: fill ?? _field,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: BorderSide.none),
      );

  Widget _participantCard(int index) {
    final item = _participants[index];
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.pal.on12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'PARTICIPANTE #${index + 1}',
                style: TextStyle(
                  color: _accent,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.1,
                ),
              ),
              if (_participants.length > 1)
                IconButton(
                  icon: Icon(Icons.remove_circle_outline, color: context.pal.bad, size: 20),
                  onPressed: () => _removeParticipantField(index),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: 'Eliminar participante',
                ),
            ],
          ),
          const SizedBox(height: 10),
          TextFormField(
            controller: item.controller,
            textCapitalization: TextCapitalization.characters,
            style: TextStyle(
              color: context.pal.on,
              fontWeight: FontWeight.w700,
              fontSize: 15,
            ),
            decoration: _decoration(
              label: 'ID / CÓDIGO *',
              hint: 'Ej. 1, 2, 3,...',
              icon: Icons.person_pin_rounded,
            ),
            validator: (val) {
              final id = (val ?? '').trim();
              if (id.isEmpty) return 'Requerido';
              if (_participants.where((p) => p.id == id).length > 1) return 'ID repetido';
              return null;
            },
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            // Built again when the visits of the project change.
            key: ValueKey('visit-${identityHashCode(item)}-${_eventOptions.keys.join('|')}'),
            initialValue: item.eventName,
            dropdownColor: _card,
            style: TextStyle(color: context.pal.on, fontWeight: FontWeight.bold, fontSize: 14),
            decoration: _decoration(label: 'MEDICIÓN / VISITA', icon: Icons.event_repeat_rounded),
            items: _eventOptions.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
            onChanged: (val) {
              if (val != null) _onMomentChanged(item, val);
            },
          ),
        ],
      ),
    );
  }

  /// The serial of each sensor of the protocol, for one participant.
  /// Devices a participant wears in the lab or takes home.
  int get _deviceCount => _layoutSensors.fold(0, (n, s) => n + (s.inLab ? 1 : 0) + (s.inFreeLiving ? 1 : 0));

  /// Devices of [group] not ready yet: not ticked, or a Polar of the
  /// laboratory not linked in the monitor.
  List<String> _uninitialized(ParticipantFieldGroup group) => [
        for (final s in _layoutSensors) ...[
          if (s.inLab && !_labReady(group, s)) s.displayName,
          if (s.inFreeLiving && !group.initialized.contains('free_living:${s.sensorId}'))
            '${s.displayName} · vida libre',
        ],
      ];

  bool _labReady(ParticipantFieldGroup group, SessionSensor s) =>
      s.connection == 'live' ? _liveOf(group, s)?.connected ?? false : group.initialized.contains('lab:${s.sensorId}');

  /// What the monitor says of the Polar [sensor] of [group].
  LiveDeviceState? _liveOf(ParticipantFieldGroup group, SessionSensor sensor) {
    for (final d in _live ?? const <LiveDeviceState>[]) {
      if (d.sensorId == sensor.sensorId && (d.participantId == null || d.participantId == group.id)) return d;
    }
    return null;
  }

  void _startLivePoll() {
    _livePoll?.cancel();
    _livePoll = Timer.periodic(const Duration(seconds: 1), (_) => unawaited(_refreshLive()));
    unawaited(_refreshLive());
  }

  void _stopLivePoll() {
    _livePoll?.cancel();
    _livePoll = null;
  }

  Future<void> _refreshLive() async {
    final live = await LiveDeviceState.query(widget.monitor);
    if (!mounted || !_waitingRoom) return;
    setState(() => _live = live);
  }

  /// The guide of [sensor]'s type, from the «i» next to it.
  Widget _guideButton(SessionSensor sensor) => IconButton(
        key: ValueKey('guide-${sensor.sensorId}-${identityHashCode(sensor)}'),
        tooltip: 'Cómo se inicializa ${sensor.deviceName}',
        visualDensity: VisualDensity.compact,
        iconSize: 18,
        color: context.pal.on60,
        icon: const Icon(Icons.info_outline_rounded),
        onPressed: () => showDeviceGuide(
          context,
          type: sensor.type,
          title: sensor.deviceName,
          dataRoot: _dataRoot,
        ),
      );

  /// The tick the evaluator marks once the device is initialized.
  Widget _initializedCheck(ParticipantFieldGroup group, SessionSensor sensor, {required bool freeLiving}) {
    final key = '${freeLiving ? 'free_living' : 'lab'}:${sensor.sensorId}';
    final done = group.initialized.contains(key);
    return Row(
      children: [
        Expanded(
          child: InkWell(
            key: ValueKey('init-${identityHashCode(group)}-$key'),
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => done ? group.initialized.remove(key) : group.initialized.add(key)),
            child: Row(
              children: [
                Checkbox(
                  value: done,
                  visualDensity: VisualDensity.compact,
                  onChanged: (v) =>
                      setState(() => v == true ? group.initialized.add(key) : group.initialized.remove(key)),
                ),
                Expanded(
                  child: Text(
                    'Inicializado',
                    style: TextStyle(color: done ? _accent : context.pal.on60, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ),
        _guideButton(sensor),
      ],
    );
  }

  /// A Polar of the laboratory: linked here, through the monitor, which
  /// keeps the link and records it.
  Widget _liveRow(ParticipantFieldGroup group, SessionSensor sensor) {
    final live = _liveOf(group, sensor);
    final pal = context.pal;
    final (text, color) = switch (live) {
      null => (_live == null ? 'Abriendo el monitor…' : 'No está en el monitor', pal.on54),
      final d when d.connected => (
          'Conectado${d.name == null ? '' : ' · ${d.name}'}${d.hr > 0 ? ' · ${d.hr} lpm' : ''}',
          pal.good,
        ),
      final d when d.busy => (d.message.isEmpty ? 'Conectando…' : d.message, pal.warn),
      final d when d.state == 'error' => (d.message.isEmpty ? 'Error de conexión' : d.message, pal.bad),
      _ => ('Sin conectar', pal.on60),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Icon(
              live?.connected == true ? Icons.bluetooth_connected_rounded : Icons.bluetooth_rounded,
              size: 18,
              color: color,
            ),
          ),
          Expanded(
            child: Text(
              text,
              key: ValueKey('live-${identityHashCode(group)}-${sensor.sensorId}'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          if (live != null && !live.busy)
            TextButton(
              key: ValueKey('connect-${identityHashCode(group)}-${sensor.sensorId}'),
              onPressed: () => live.connected ? _disconnectLive(live, sensor) : _connectLive(live, sensor),
              child: Text(live.connected ? 'Desconectar' : 'Conectar'),
            ),
          _guideButton(sensor),
        ],
      ),
    );
  }

  Future<void> _connectLive(LiveDeviceState live, SessionSensor sensor) async {
    final message = await showLiveConnectDialog(
      context,
      monitor: widget.monitor,
      deviceId: live.deviceId,
      title: sensor.displayName,
    );
    await _refreshLive();
    if (message == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _disconnectLive(LiveDeviceState live, SessionSensor sensor) async {
    await widget.monitor.send(WindowMessages.liveDisconnect, {'device_id': live.deviceId});
    await _refreshLive();
  }

  Widget _participantSensorsCard(ParticipantFieldGroup group, int index) {
    final layout = _layoutSensors;
    final missing = _missingSerials(group).length;
    final pending = _uninitialized(group).length;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.pal.on12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.watch_rounded, color: _accent, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'SENSORES DE ${group.id.isEmpty ? 'PARTICIPANTE #${index + 1}' : group.id}',
                  style: TextStyle(
                    color: _accent,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.1,
                  ),
                ),
              ),
              if (layout.isNotEmpty)
                Text(
                  '${missing == 0 ? 'Todos con número de serie' : '$missing sin número de serie'} · '
                  '${_deviceCount - pending}/$_deviceCount listos',
                  key: ValueKey('init-count-$index'),
                  style: TextStyle(color: missing == 0 && pending == 0 ? context.pal.on54 : _warning, fontSize: 12),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (layout.isEmpty)
            Text(
              'El protocolo no tiene sensores.',
              style: TextStyle(color: context.pal.on54, fontSize: 12),
            )
          else
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final sensor in layout)
                  SizedBox(
                    width: 282,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (sensor.inLab)
                          TextFormField(
                            key: ValueKey('serial-${identityHashCode(group)}-${sensor.sensorId}'),
                            controller: _serialController(group, sensor),
                            onChanged: (_) => setState(() {}),
                            style: TextStyle(color: context.pal.on, fontWeight: FontWeight.w600, fontSize: 13),
                            decoration: _decoration(
                              label: sensor.displayName,
                              hint: 'Número de serie',
                            ).copyWith(isDense: true),
                          ),
                        if (sensor.inLab)
                          if (sensor.connection == 'live')
                            _liveRow(group, sensor)
                          else
                            _initializedCheck(group, sensor, freeLiving: false),
                        // The device taken home for the free-living days
                        // (another one, with its own serial), so its
                        // calibration reaches this participant too.
                        if (sensor.inFreeLiving) ...[
                          if (sensor.inLab) const SizedBox(height: 4),
                          TextFormField(
                            key: ValueKey('fl-serial-${identityHashCode(group)}-${sensor.sensorId}'),
                            controller: _freeLivingSerialController(group, sensor),
                            onChanged: (_) => setState(() {}),
                            style: TextStyle(
                              color: sensor.inLab ? context.pal.on70 : context.pal.on,
                              fontSize: sensor.inLab ? 12 : 13,
                              fontWeight: sensor.inLab ? null : FontWeight.w600,
                            ),
                            decoration: _decoration(
                              label: sensor.inLab ? 'Vida libre' : '${sensor.displayName} · vida libre',
                              hint: 'Número de serie del que se lleva',
                            ).copyWith(isDense: true),
                          ),
                          _initializedCheck(group, sensor, freeLiving: true),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  /// The parent folder and, below, the folder each participant gets.
  Widget _foldersCard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.pal.on12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(Icons.folder_rounded, color: _accent, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'CARPETA MADRE',
                  style: TextStyle(color: context.pal.on60, fontSize: 12),
                ),
                const SizedBox(height: 2),
                SelectableText(
                  _dataRoot ?? '...',
                  key: const Key('data_root'),
                  style: TextStyle(color: context.pal.on, fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  'Se crearán:',
                  style: TextStyle(color: context.pal.on38, fontSize: 11),
                ),
                for (final group in _participants)
                  SelectableText(
                    _folderOf(group),
                    style: TextStyle(color: context.pal.on54, fontSize: 11),
                  ),
                const SizedBox(height: 6),
                Text(
                  'Marcas, Polar, vídeo, calibración y manifiesto para SAVES se guardan ahí mientras ocurre. '
                  'Mejor un disco local (no una carpeta sincronizada).',
                  style: TextStyle(color: context.pal.on38, fontSize: 11),
                ),
              ],
            ),
          ),
          TextButton(onPressed: _chooseDataRoot, child: const Text('Cambiar')),
        ],
      ),
    );
  }

  /// Calibration of the offline sensors before the session.
  Widget _calibrationCard() {
    final calibrations = _calibrations;
    final c = calibrations.isEmpty ? null : calibrations.first;
    final missing = _participantsReady ? _uncalibrated(_entries(), calibrations).length : 0;
    String two(int v) => v.toString().padLeft(2, '0');
    String hhmm(DateTime t) => '${two(t.toLocal().hour)}:${two(t.toLocal().minute)}';
    final devices = {for (final r in calibrations) ...r.devices}.length;
    final status = c == null
        ? 'Sin calibrar hoy. Mientras el participante hace los cuestionarios, calibra aquí sus sensores, ya grabando.'
        : '${calibrations.length == 1 ? 'Calibración' : '${calibrations.length} calibraciones'} de hoy '
            '(la última ${hhmm(c.start)}–${hhmm(c.end)}), $devices '
            '${devices == 1 ? 'dispositivo' : 'dispositivos'}. '
            '${missing > 0 ? 'Faltan $missing ${missing == 1 ? 'sensor' : 'sensores'} de los participantes.' : 'Pasará a la carpeta de cada participante al empezar.'}';
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c == null || missing > 0 ? _warning.withAlpha(120) : context.pal.on12),
      ),
      child: Row(
        children: [
          Icon(
            c == null || missing > 0 ? Icons.warning_amber_rounded : Icons.check_circle_rounded,
            color: c == null || missing > 0 ? _warning : _accent,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'CALIBRACIÓN DE LOS SENSORES',
                  style: TextStyle(color: context.pal.on60, fontSize: 12),
                ),
                const SizedBox(height: 2),
                Text(
                  status,
                  style: TextStyle(color: context.pal.on, fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            key: const Key('calibrate'),
            onPressed: _starting ? null : _calibrate,
            icon: const Icon(Icons.threed_rotation_rounded, size: 18),
            label: const Text('Calibración'),
          ),
        ],
      ),
    );
  }

  /// The Polar and the camera are connected in the Research Monitor.
  Widget _monitorCard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.pal.on12),
      ),
      child: Row(
        children: [
          Icon(Icons.monitor_heart_rounded, color: _accent, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'RESEARCH MONITOR',
                  style: TextStyle(color: context.pal.on60, fontSize: 12),
                ),
                const SizedBox(height: 2),
                Text(
                  'Las Polar se conectan arriba, junto a cada participante; la cámara se elige en el monitor. '
                  'Todo sigue conectado al pasar a la sesión, y si algo falla se reconecta en la barra de '
                  'dispositivos del monitor. La sesión se empieza allí, con «Empezar sesión».',
                  style: TextStyle(color: context.pal.on, fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            key: const Key('show_monitor'),
            onPressed: widget.onPrepare == null ? null : _openMonitor,
            icon: const Icon(Icons.open_in_new_rounded, size: 18),
            label: const Text('Mostrar monitor'),
          ),
        ],
      ),
    );
  }

  /// Between the session data and the session: the sensors are got ready
  /// (serial numbers, Polar and camera, calibration) while the participant
  /// fills the questionnaires with another evaluator.
  Widget _waitingRoomColumn() {
    final count = _participants.length;
    final ids = [for (final p in _participants) p.id].join(', ');
    return Column(
      key: const Key('waiting_room'),
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _accent.withAlpha(30),
              border: Border.all(color: _accent.withAlpha(100), width: 2),
            ),
            child: Icon(Icons.meeting_room_rounded, size: 54, color: _accent),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'SALA DE ESPERA',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: 2.0, color: context.pal.on),
        ),
        const SizedBox(height: 6),
        Text(
          '$ids · ${_sessionBattery?.displayName ?? 'sin protocolo'}',
          textAlign: TextAlign.center,
          style: TextStyle(color: context.pal.on70, fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          'Mientras el participante hace los cuestionarios con un evaluador, otro prepara aquí sus sensores.',
          textAlign: TextAlign.center,
          style: TextStyle(color: context.pal.on54, fontSize: 12),
        ),
        const SizedBox(height: 28),
        _SetupSection(
          number: 1,
          title: 'NÚMEROS DE SERIE',
          enabled: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < count; i++) ...[
                if (i > 0) const SizedBox(height: 10),
                _participantSensorsCard(_participants[i], i),
              ],
              const SizedBox(height: 6),
              Text(
                'Cada participante lleva los sensores del protocolo; su número de serie va al manifiesto y a '
                'REDCap, y decide qué calibración es suya. Las cámaras son de la sesión.',
                style: TextStyle(color: context.pal.on38, fontSize: 11),
              ),
            ],
          ),
        ),
        const SizedBox(height: 28),
        _SetupSection(
          number: 2,
          title: 'CÁMARA Y MONITOR',
          enabled: true,
          child: _monitorCard(),
        ),
        const SizedBox(height: 28),
        _SetupSection(
          number: 3,
          title: 'CALIBRACIÓN',
          enabled: true,
          child: _calibrationCard(),
        ),
        const SizedBox(height: 28),
        SizedBox(
          width: double.infinity,
          height: 54,
          child: FilledButton.icon(
            key: const Key('go_to_session'),
            onPressed: _starting ? null : _submitAndStart,
            style: FilledButton.styleFrom(
              backgroundColor: _accent,
              foregroundColor: context.pal.onAccent,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
            icon: const Icon(Icons.arrow_forward_rounded, size: 24),
            label: Text(
              'PASAR A LA SESIÓN ($count SUJETO${count > 1 ? 'S' : ''})',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900, letterSpacing: 1.2),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Center(
          child: TextButton.icon(
            key: const Key('leave_waiting_room'),
            onPressed: _starting ? null : _leaveWaitingRoom,
            style: TextButton.styleFrom(foregroundColor: context.pal.on60),
            icon: const Icon(Icons.arrow_back_rounded, size: 18),
            label: const Text('Volver a los datos de la sesión'),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ready = _participantsReady;
    final count = _participants.length;
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.center,
            radius: 1.3,
            colors: [context.pal.surface, context.pal.canvasMain],
          ),
        ),
        child: SafeArea(
          child: Stack(
            children: [
              Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 28.0, vertical: 24.0),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: Form(
                      key: _formKey,
                      child: _waitingRoom
                          ? _waitingRoomColumn()
                          : Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Center(
                                  child: Container(
                                    padding: const EdgeInsets.all(18),
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: _accent.withAlpha(30),
                                      border: Border.all(
                                        color: _accent.withAlpha(100),
                                        width: 2,
                                      ),
                                    ),
                                    child: Icon(
                                      Icons.groups_rounded,
                                      size: 54,
                                      color: _accent,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 20),
                                Text(
                                  'NUEVA SESIÓN',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 2.0,
                                    color: context.pal.on,
                                  ),
                                ),
                                const SizedBox(height: 28),

                                // 1. Participants
                                _SetupSection(
                                  number: 1,
                                  title: 'PARTICIPANTES',
                                  enabled: true,
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      for (var i = 0; i < count; i++) ...[
                                        if (i > 0) const SizedBox(height: 14),
                                        _participantCard(i),
                                      ],
                                      const SizedBox(height: 12),
                                      Align(
                                        alignment: Alignment.centerLeft,
                                        child: OutlinedButton.icon(
                                          onPressed: _addParticipantField,
                                          style: OutlinedButton.styleFrom(
                                            foregroundColor: _accent,
                                            side: BorderSide(color: _accent),
                                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                          ),
                                          icon: const Icon(Icons.add_rounded),
                                          label: const Text('Añadir Otro Participante'),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),

                                const SizedBox(height: 28),

                                // 2. Protocol and sensors of each participant
                                _SetupSection(
                                  number: 2,
                                  title: 'PROTOCOLO Y SENSORES',
                                  enabled: ready,
                                  hint: 'Escribe el ID de cada participante para configurar el protocolo.',
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      SessionSetupCard(
                                        protocols: _allProtocols,
                                        battery: _sessionBattery,
                                        modified: _batteryModified,
                                        note: _setupNote,
                                        loading: _loadingProtocols,
                                        missingSerials: 0, // typed in the waiting room
                                        onSelect: _selectProtocol,
                                        onEdit: _editProtocol,
                                        onImport: _loadBattery,
                                        onReset: _batteryModified ? () => _selectProtocol(_battery?.protocolId) : null,
                                        onDeleteCustom:
                                            _customProtocols.any((p) => p.protocolId == _battery?.protocolId)
                                                ? _deleteCustomProtocol
                                                : null,
                                        onSyncKind: _chooseSyncKind,
                                      ),
                                      if (_battery != null) ...[
                                        const SizedBox(height: 6),
                                        Text(
                                          'Los números de serie de los sensores se escriben en la sala de espera, '
                                          'al preparar la sesión.',
                                          style: TextStyle(color: context.pal.on38, fontSize: 11),
                                        ),
                                      ],
                                      const SizedBox(height: 14),
                                      TextFormField(
                                        controller: _activityController,
                                        keyboardType: TextInputType.number,
                                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                                        style:
                                            TextStyle(color: context.pal.on, fontWeight: FontWeight.w700, fontSize: 16),
                                        decoration: _decoration(
                                          label: 'ACTIVIDAD INICIAL *',
                                          hint: 'Ej. 1',
                                          icon: Icons.pin_rounded,
                                          fill: _card,
                                          radius: 16,
                                        ),
                                        validator: (value) {
                                          final numVal = int.tryParse(value ?? '');
                                          if (numVal == null || numVal < 1) return 'Debe ser mínimo 1';
                                          return null;
                                        },
                                      ),
                                    ],
                                  ),
                                ),

                                const SizedBox(height: 28),

                                // 3. One folder per participant
                                _SetupSection(
                                  number: 3,
                                  title: 'CARPETAS DE LA SESIÓN',
                                  enabled: ready,
                                  hint: 'Escribe el ID de cada participante para ver sus carpetas.',
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      _foldersCard(),
                                    ],
                                  ),
                                ),

                                const SizedBox(height: 24),
                                _operatorsCard(),
                                const SizedBox(height: 14),
                                _redcapCard(),

                                const SizedBox(height: 28),
                                SizedBox(
                                  width: double.infinity,
                                  height: 54,
                                  child: FilledButton.icon(
                                    key: const Key('prepare_session'),
                                    onPressed: _starting || !ready ? null : _prepare,
                                    style: FilledButton.styleFrom(
                                      backgroundColor: _accent,
                                      foregroundColor: context.pal.onAccent,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                    ),
                                    icon: const Icon(Icons.arrow_forward_rounded, size: 24),
                                    label: Text(
                                      'PREPARAR SESIÓN ($count SUJETO${count > 1 ? 'S' : ''})',
                                      style: const TextStyle(
                                          fontSize: 15, fontWeight: FontWeight.w900, letterSpacing: 1.2),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Center(
                                  child: Tooltip(
                                    message: 'Para una sesión que se guardó sin llegar a REDCap: elige su carpeta '
                                        '(por ejemplo R4H_001\\D0) y se envía lo que quedó pendiente.',
                                    child: TextButton.icon(
                                      onPressed: _sendingSaved ? null : _sendSavedSession,
                                      style: TextButton.styleFrom(foregroundColor: context.pal.on60),
                                      icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                                      label: Text(_sendingSaved
                                          ? 'Enviando a REDCap…'
                                          : 'Enviar a REDCap una sesión guardada…'),
                                    ),
                                  ),
                                ),
                                Center(
                                  child: Tooltip(
                                    message:
                                        'Para los registros de los móviles (healthy_tracker): elige la carpeta de Google '
                                        'Drive del estudio, o la de un archivo copiado del móvil por cable. Lo que REDCap ya '
                                        'tiene no se repite.',
                                    child: TextButton.icon(
                                      key: const ValueKey('send_phone_records'),
                                      onPressed: _sendingPhone != null ? null : _sendPhoneRecords,
                                      style: TextButton.styleFrom(foregroundColor: context.pal.on60),
                                      icon: const Icon(Icons.phone_android_outlined, size: 18),
                                      label: Text(_sendingPhone == null
                                          ? 'Enviar a REDCap los registros del móvil (healthy_tracker)…'
                                          : 'Enviando los registros del móvil${_sendingPhone!.isEmpty ? '' : ' ($_sendingPhone)'}…'),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ),
                ),
              ),
              const Positioned(top: 8, right: 8, child: ThemeToggleButton()),
            ],
          ),
        ),
      ),
    );
  }
}

/// One numbered step of the start screen. A step that is not [enabled]
/// yet is shown dimmed, takes no taps and says what it waits for.
class _SetupSection extends StatelessWidget {
  const _SetupSection({
    required this.number,
    required this.title,
    required this.enabled,
    required this.child,
    this.hint,
  });

  final int number;
  final String title;
  final bool enabled;
  final Widget child;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: enabled ? _accent : context.pal.on12,
              ),
              child: Text(
                '$number',
                style: TextStyle(
                  color: enabled ? context.pal.onAccent : context.pal.on38,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              title,
              style: TextStyle(
                color: enabled ? context.pal.on : context.pal.on38,
                fontSize: 14,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.6,
              ),
            ),
          ],
        ),
        if (!enabled && hint != null)
          Padding(
            padding: const EdgeInsets.only(left: 38, top: 4),
            child: Text(
              hint!,
              key: ValueKey('setup_section_${number}_hint'),
              style: TextStyle(color: _warning, fontSize: 12),
            ),
          ),
        const SizedBox(height: 12),
        ExcludeFocus(
          excluding: !enabled,
          child: AbsorbPointer(
            absorbing: !enabled,
            child: Opacity(opacity: enabled ? 1 : 0.4, child: child),
          ),
        ),
      ],
    );
  }
}
