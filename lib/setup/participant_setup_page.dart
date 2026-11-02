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

const _accent = Color(0xFF38BDF8);
const _card = Color(0xFF1E293B);
const _field = Color(0xFF0F172A);
const _warning = Color(0xFFFBBF24);

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

  void dispose() {
    controller.dispose();
    for (final c in serials.values) {
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
    this.checkUnfinished = true,
  });

  final SessionStarter onStart;
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
  final _operatorController = TextEditingController();
  String? _dataRoot;

  /// Calibration of the sensors done today under the data folder.
  List<CalibrationRecord> _calibrations = const [];
  bool _starting = false;
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
  bool get _participantsReady =>
      _participants.isNotEmpty && _participants.every((p) => p.id.isNotEmpty);

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
    String? operator;
    String? syncKind;
    try {
      final prefs = await SharedPreferences.getInstance();
      root = prefs.getString(SetupPrefs.dataRoot);
      operator = prefs.getString(SetupPrefs.operator);
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
      if (operator != null && _operatorController.text.isEmpty) _operatorController.text = operator;
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
        for (final s in offline)
          if (_serialFor(group, s) case final serial?) CalibrationDevice(s.type, serial),
    };
    if (typed.isNotEmpty) return typed.toList();
    return [for (final s in offline) CalibrationDevice(s.type, '')];
  }

  /// Offline sensors of [entries] without a calibration of today, as
  /// «P01: AX6 · Pie izquierdo (1234)».
  List<String> _uncalibrated(List<ParticipantEntry> entries, List<CalibrationRecord> records) => [
        for (final p in entries)
          for (final s in p.sensors)
            if (s.connection == 'offline' &&
                s.type != 'other' &&
                CalibrationStore.forDevice(records, s.type, s.serial) == null)
              '${p.participantId}: ${s.displayName}${s.hasSerial ? ' (${s.serial!.trim()})' : ' (sin número de serie)'}',
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

  List<ActivityBattery> get _allProtocols =>
      [..._builtInProtocols, ..._customProtocols];

  ActivityBattery? _protocolById(String? id) {
    for (final p in _allProtocols) {
      if (p.protocolId == id) return p;
    }
    return null;
  }

  bool get _batteryModified {
    final saved = _protocolById(_battery?.protocolId);
    return saved != null &&
        jsonEncode(saved.toJson()) != jsonEncode(_battery!.toJson());
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
    final initial = remembered ??
        (_participants.length == 1 && sensor.hasSerial ? sensor.serial!.trim() : '');
    return group.serialOf(sensor.sensorId, initial: initial);
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

  /// Sensors of [group] without a serial number.
  List<SessionSensor> _missingSerials(ParticipantFieldGroup group) => [
        for (final sensor in _layoutSensors)
          if (_serialFor(group, sensor) == null) sensor,
      ];

  int get _missingSerialCount =>
      _participants.fold(0, (sum, g) => sum + _missingSerials(g).length);

  /// Fills the serial fields of [group] from a remembered setup.
  void _fillSerials(ParticipantFieldGroup group, List<SessionSensor> remembered) {
    for (final sensor in _layoutSensors) {
      for (final old in remembered) {
        if (old.sensorId == sensor.sensorId && old.type == sensor.type) {
          group.serialOf(sensor.sensorId).text = old.hasSerial ? old.serial!.trim() : '';
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
        final protocol =
            ProtocolLibrary.forMoment(saved, group.eventName, _allProtocols) ?? saved;
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
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
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
    RedcapConnection.changes.removeListener(_onRedcapChanged);
    for (final p in _participants) {
      p.dispose();
    }
    _activityController.dispose();
    _operatorController.dispose();
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
        title: const Row(
          children: [
            Icon(Icons.history_rounded, color: Color(0xFFFBBF24)),
            SizedBox(width: 10),
            Text('Sesión sin terminar'),
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
            style: const TextStyle(color: Colors.white70, height: 1.4),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop('later'),
            child: const Text('Ahora no'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
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
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
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
              if (_serialFor(group, sensor) case final serial?)
                sensor.copyWith(serial: serial)
              else
                sensor.copyWith(clearSerial: true),
          ],
        ),
    ];
  }

  Future<void> _submitAndStart() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    if (!_participantsReady) return;

    final entries = _entries();
    final activity =
        int.tryParse(_activityController.text.trim()) ?? 1;

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
          if (_missingSerials(group) case final sensors when sensors.isNotEmpty)
            '${group.id}: ${sensors.map((s) => s.sensorId).join(', ')}',
      ];
      if (missing.isNotEmpty) {
        final proceed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: _card,
            title: const Text('Faltan números de serie'),
            content: Text(
              'Sin número de serie:\n${missing.join('\n')}\n\n'
              'Se escriben en «Protocolo y sensores», junto a cada participante. '
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
          backgroundColor: Colors.redAccent,
          content: Text('No se puede usar la carpeta de datos $root: $e'),
        ),
      );
      return;
    }
    final operator = _operatorController.text.trim();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(SetupPrefs.dataRoot, root);
      await prefs.setString(SetupPrefs.operator, operator);
    } catch (_) {}

    final controller = SessionController(
      participants: entries,
      battery: battery,
      dataRoot: root,
      calibrations: calibrations,
      // A protocol can run its activities one after another (lap_mode false).
      settings: SessionSettings(lapMode: battery?.lapMode ?? true),
      operator: operator.isEmpty ? null : operator,
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
    try {
      await widget.onStart(controller);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  /// Where the sessions go besides their folder: REDCap, if there is a token.
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
            color: configured ? const Color(0xFF38BDF8) : Colors.white38,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'REDCAP (OPCIONAL)',
                  style: TextStyle(color: Colors.white60, fontSize: 12),
                ),
                const SizedBox(height: 2),
                Text(
                  status,
                  style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
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
    Color fill = _field,
    double radius = 12,
  }) =>
      InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white60, fontSize: 12),
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white24),
        prefixIcon: icon == null ? null : Icon(icon, color: _accent, size: 20),
        filled: true,
        fillColor: fill,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: BorderSide.none),
      );

  Widget _participantCard(int index) {
    final item = _participants[index];
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'PARTICIPANTE #${index + 1}',
                style: const TextStyle(
                  color: _accent,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.1,
                ),
              ),
              if (_participants.length > 1)
                IconButton(
                  icon: const Icon(Icons.remove_circle_outline, color: Colors.redAccent, size: 20),
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
            style: const TextStyle(
              color: Colors.white,
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
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
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
  Widget _participantSensorsCard(ParticipantFieldGroup group, int index) {
    final layout = _layoutSensors;
    final missing = _missingSerials(group).length;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.watch_rounded, color: _accent, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'SENSORES DE ${group.id.isEmpty ? 'PARTICIPANTE #${index + 1}' : group.id}',
                  style: const TextStyle(
                    color: _accent,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.1,
                  ),
                ),
              ),
              if (layout.isNotEmpty)
                Text(
                  missing == 0 ? 'Todos con número de serie' : '$missing sin número de serie',
                  style: TextStyle(color: missing == 0 ? Colors.white54 : _warning, fontSize: 12),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (layout.isEmpty)
            const Text(
              'El protocolo no tiene sensores.',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            )
          else
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final sensor in layout)
                  SizedBox(
                    width: 282,
                    child: TextFormField(
                      key: ValueKey('serial-${identityHashCode(group)}-${sensor.sensorId}'),
                      controller: _serialController(group, sensor),
                      onChanged: (_) => setState(() {}),
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
                      decoration: _decoration(
                        label: sensor.displayName,
                        hint: 'Número de serie',
                      ).copyWith(isDense: true),
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
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(Icons.folder_rounded, color: _accent, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'CARPETA MADRE',
                  style: TextStyle(color: Colors.white60, fontSize: 12),
                ),
                const SizedBox(height: 2),
                SelectableText(
                  _dataRoot ?? '...',
                  key: const Key('data_root'),
                  style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Se crearán:',
                  style: TextStyle(color: Colors.white38, fontSize: 11),
                ),
                for (final group in _participants)
                  SelectableText(
                    _folderOf(group),
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                const SizedBox(height: 6),
                const Text(
                  'Marcas, Polar, vídeo, calibración y manifiesto para SAVES se guardan ahí mientras ocurre. '
                  'Mejor un disco local (no una carpeta sincronizada).',
                  style: TextStyle(color: Colors.white38, fontSize: 11),
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
        ? 'Sin calibrar hoy. Hazla antes de que llegue el participante, con los sensores ya grabando.'
        : '${calibrations.length == 1 ? 'Calibración' : '${calibrations.length} calibraciones'} de hoy '
            '(la última ${hhmm(c.start)}–${hhmm(c.end)}), $devices '
            '${devices == 1 ? 'dispositivo' : 'dispositivos'}. '
            '${missing > 0 ? 'Faltan $missing ${missing == 1 ? 'sensor' : 'sensores'} de los participantes.' : 'Pasará a la carpeta de cada participante al empezar.'}';
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c == null || missing > 0 ? _warning.withAlpha(120) : Colors.white12),
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
                const Text(
                  'CALIBRACIÓN DE LOS SENSORES',
                  style: TextStyle(color: Colors.white60, fontSize: 12),
                ),
                const SizedBox(height: 2),
                Text(
                  status,
                  style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
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

  @override
  Widget build(BuildContext context) {
    final ready = _participantsReady;
    final count = _participants.length;
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.center,
            radius: 1.3,
            colors: [Color(0xFF1E293B), Color(0xFF0B0F19)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28.0, vertical: 24.0),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Form(
                  key: _formKey,
                  child: Column(
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
                          child: const Icon(
                            Icons.groups_rounded,
                            size: 54,
                            color: _accent,
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'NUEVA SESIÓN',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 2.0,
                          color: Colors.white,
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
                                  side: const BorderSide(color: _accent),
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
                              missingSerials: _missingSerialCount,
                              onSelect: _selectProtocol,
                              onEdit: _editProtocol,
                              onImport: _loadBattery,
                              onReset: _batteryModified
                                  ? () => _selectProtocol(_battery?.protocolId)
                                  : null,
                              onDeleteCustom: _customProtocols.any(
                                      (p) => p.protocolId == _battery?.protocolId)
                                  ? _deleteCustomProtocol
                                  : null,
                              onSyncKind: _chooseSyncKind,
                            ),
                            if (_battery != null) ...[
                              const SizedBox(height: 14),
                              for (var i = 0; i < count; i++) ...[
                                if (i > 0) const SizedBox(height: 10),
                                _participantSensorsCard(_participants[i], i),
                              ],
                              const SizedBox(height: 6),
                              const Text(
                                'Cada participante lleva los sensores del protocolo; su número de serie se '
                                'escribe aquí y va al manifiesto y a REDCap. Las cámaras son de la sesión.',
                                style: TextStyle(color: Colors.white38, fontSize: 11),
                              ),
                            ],
                            const SizedBox(height: 14),
                            TextFormField(
                              controller: _activityController,
                              keyboardType: TextInputType.number,
                              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16),
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
                      TextFormField(
                        controller: _operatorController,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15),
                        decoration: _decoration(
                          label: 'EVALUADOR/A',
                          hint: 'Nombre o iniciales (va a REDCap y al manifiesto)',
                          icon: Icons.badge_rounded,
                          fill: _card,
                          radius: 16,
                        ),
                      ),
                      const SizedBox(height: 14),
                      _redcapCard(),
                      const SizedBox(height: 14),
                      _calibrationCard(),

                      const SizedBox(height: 28),
                      SizedBox(
                        width: double.infinity,
                        height: 54,
                        child: FilledButton.icon(
                          onPressed: _starting || !ready ? null : _submitAndStart,
                          style: FilledButton.styleFrom(
                            backgroundColor: _accent,
                            foregroundColor: Colors.black,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          ),
                          icon: const Icon(Icons.arrow_forward_rounded, size: 24),
                          label: Text(
                            'COMENZAR SESIÓN ($count SUJETO${count > 1 ? 'S' : ''})',
                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900, letterSpacing: 1.2),
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
                            style: TextButton.styleFrom(foregroundColor: Colors.white60),
                            icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                            label: Text(_sendingSaved ? 'Enviando a REDCap…' : 'Enviar a REDCap una sesión guardada…'),
                          ),
                        ),
                      ),
                      Center(
                        child: Tooltip(
                          message: 'Para los registros de los móviles (healthy_tracker): elige la carpeta de Google '
                              'Drive del estudio, o la de un archivo copiado del móvil por cable. Lo que REDCap ya '
                              'tiene no se repite.',
                          child: TextButton.icon(
                            key: const ValueKey('send_phone_records'),
                            onPressed: _sendingPhone != null ? null : _sendPhoneRecords,
                            style: TextButton.styleFrom(foregroundColor: Colors.white60),
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
                color: enabled ? _accent : Colors.white12,
              ),
              child: Text(
                '$number',
                style: TextStyle(
                  color: enabled ? Colors.black : Colors.white38,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              title,
              style: TextStyle(
                color: enabled ? Colors.white : Colors.white38,
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
              style: const TextStyle(color: _warning, fontSize: 12),
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
