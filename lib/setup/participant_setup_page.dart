import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/activity_battery.dart';
import '../services/lab_redcap_service.dart';
import '../services/protocol_library.dart';
import '../services/redcap_resend.dart';
import '../session/session_controller.dart';
import '../session/session_store.dart';
import 'protocol_editor_page.dart';
import 'session_setup_card.dart';

class ParticipantFieldGroup {
  final TextEditingController controller;
  String eventName;

  ParticipantFieldGroup({
    required this.controller,
    this.eventName = 'da_0__visita_inici_arm_1',
  });
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
  bool _starting = false;
  bool _sendingSaved = false;

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

  /// Participant whose remembered setup is loaded, and what was loaded.
  String? _rememberedFor;
  String? _setupNote;

  static const Map<String, String> _eventOptions = {
    'da_0__visita_inici_arm_1': 'Visita Inicial (Día 0)',
    'da_8__visita_final_arm_1': 'Visita Final (Día 8)',
  };

  @override
  void initState() {
    super.initState();

    _addParticipantField(); // Default - 1 participant
    _loadProtocols();
    _loadPrefs();
  }

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
    if (widget.checkUnfinished) await _checkUnfinishedSessions();
  }

  Future<void> _chooseDataRoot() async {
    final chosen = await getDirectoryPath(
      confirmButtonText: 'Usar esta carpeta',
      initialDirectory: _dataRoot,
    );
    if (chosen == null || !mounted) return;
    setState(() => _dataRoot = chosen);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(SetupPrefs.dataRoot, chosen);
    } catch (_) {}
  }

  /// Where the first participant's visit would be saved.
  String get _folderPreview {
    final root = _dataRoot ?? '...';
    if (_participants.isEmpty) return root;
    final ids = [
      for (final p in _participants)
        ParticipantEntry(participantId: p.controller.text.trim().isEmpty ? '<ID>' : p.controller.text.trim(),
            redcapEventName: p.eventName),
    ];
    final sep = Platform.pathSeparator;
    return '$root$sep${SessionStore.participantFolder(_battery?.study, ids)}$sep'
        '${SessionStore.visitCode(_participants.first.eventName)}';
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
      _applyRememberedSetup();
    } catch (e) {
      debugPrint('[SETUP] No se pudieron cargar los protocolos: $e');
      if (mounted) setState(() => _loadingProtocols = false);
    }
  }

  /// When the first participant already had a session on this computer, load
  /// its sensors (and serials) into the protocol of this visit.
  void _applyRememberedSetup() {
    if (_loadingProtocols || _participants.isEmpty) return;
    final first = _participants.first;
    final id = first.controller.text.trim();
    if (id == _rememberedFor) return;

    final remembered = _rememberedSetups[id];
    if (remembered == null) {
      if (_rememberedFor != null) {
        // Another participant: back to the plain protocol of this visit.
        setState(() {
          _rememberedFor = null;
          _setupNote = null;
          final plain = _protocolById(_battery?.protocolId);
          if (plain != null) _battery = plain;
        });
      }
      return;
    }

    final saved = _protocolById(remembered.battery.protocolId) ??
        remembered.battery;
    final protocol =
        ProtocolLibrary.forMoment(saved, first.eventName, _allProtocols) ??
            saved;
    final visit = _eventOptions[remembered.eventName] ?? remembered.eventName;
    final when = remembered.savedAt.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');

    setState(() {
      _battery = ProtocolLibrary.applyRemembered(protocol, remembered);
      _rememberedFor = id;
      _setupNote = 'Sensores y números de serie de la sesión anterior de $id '
          '($visit, ${two(when.day)}/${two(when.month)} ${two(when.hour)}:${two(when.minute)}).';
    });
  }

  void _onMomentChanged(ParticipantFieldGroup item, String moment) {
    setState(() => item.eventName = moment);
    if (item != _participants.first || _battery == null) return;

    final next = ProtocolLibrary.forMoment(_battery!, moment, _allProtocols);
    if (next == null || next.protocolId == _battery!.protocolId) return;
    final remembered = _rememberedSetups[_rememberedFor];
    setState(() {
      _battery = remembered != null
          ? ProtocolLibrary.applyRemembered(next, remembered)
          : ProtocolLibrary.carrySensorDetails(next, _battery!.sensors);
    });
  }

  void _selectProtocol(String? id) {
    if (id == _battery?.protocolId && !_batteryModified) return;
    final selected = _protocolById(id);
    setState(() {
      _setupNote = null;
      _rememberedFor = null;
      _battery = selected == null
          ? (id == null ? null : _battery)
          : ProtocolLibrary.carrySensorDetails(
              selected,
              _battery?.sensors ?? const [],
            );
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
    setState(() => _battery = edited);
  }

  /// Sends to REDCap a saved session whose records did not get there (the
  /// app was closed, there was no network or the REDCap project needed a
  /// change).
  Future<void> _sendSavedSession() async {
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
        backgroundColor: const Color(0xFF1E293B),
        title: Text(error == null ? 'Sesión enviada a REDCap' : 'No se pudo enviar'),
        content: SelectableText(error ?? 'REDCap ya tiene los registros de $chosen.'),
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
        backgroundColor: const Color(0xFF1E293B),
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
      _battery = _builtInProtocols.isEmpty ? null : _builtInProtocols.first;
    });
  }

  void _addParticipantField([String initialId = '', String initialEvent = 'da_0__visita_inici_arm_1']) {
    setState(() {
      _participants.add(
        ParticipantFieldGroup(
          controller: TextEditingController(text: initialId)
            ..addListener(_applyRememberedSetup),
          eventName: initialEvent,
        ),
      );
    });
  }

  void _removeParticipantField(int index) {
    if (_participants.length > 1) {
      setState(() {
        _participants[index].controller.dispose();
        _participants.removeAt(index);
      });
    }
  }

  @override
  void dispose() {
    for (final p in _participants) {
      p.controller.dispose();
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
        backgroundColor: const Color(0xFF1E293B),
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
        backgroundColor: const Color(0xFF1E293B),
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
        _battery = battery;
        _setupNote = 'Importado de ${file.name}. Para tenerlo en la lista, '
            'ábrelo en «Editar» y guárdalo como protocolo.';
        _rememberedFor = null;
      });
    } on FormatException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Protocolo no válido: ${e.message}')),
      );
    }
  }

  Future<void> _submitAndStart() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }

    final List<ParticipantEntry> entries = _participants.map((p) {
      return ParticipantEntry(
        participantId: p.controller.text.trim(),
        redcapEventName: p.eventName,
      );
    }).toList();

    final activity =
        int.tryParse(_activityController.text.trim()) ?? 1;

    final battery = _sessionBattery;
    if (battery != null) {
      final missing = battery.sensors
          .where((s) => s.connection != 'video' && !s.hasSerial)
          .map((s) => s.sensorId)
          .toList();
      if (missing.isNotEmpty) {
        final proceed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: const Color(0xFF1E293B),
            title: const Text('Faltan números de serie'),
            content: Text(
              'Sin número de serie: ${missing.join(', ')}.\n\n'
              'Se pueden añadir en «Editar actividades y sensores». '
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
      await ProtocolLibrary.remember(
        entries.map(
          (e) => (participantId: e.participantId, eventName: e.redcapEventName),
        ),
        _battery ?? battery,
      );
    }

    if (!mounted) return;

    final root = _dataRoot ?? await SetupPrefs.defaultDataRoot();
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

  @override
  Widget build(BuildContext context) {
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
                    children: [
                      Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFF38BDF8).withAlpha(30),
                          border: Border.all(
                            color: const Color(0xFF38BDF8).withAlpha(100),
                            width: 2,
                          ),
                        ),
                        child: const Icon(
                          Icons.groups_rounded,
                          size: 54,
                          color: Color(0xFF38BDF8),
                        ),
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'PARTICIPANTES A EVALUAR',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 2.0,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const SizedBox(height: 28),

                      // Dynamic list of participants
                      ListView.separated(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: _participants.length,
                        separatorBuilder: (context, index) => const SizedBox(height: 14),
                        itemBuilder: (context, index) {
                          final item = _participants[index];
                          return Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1E293B),
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
                                        color: Color(0xFF38BDF8),
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
                                  decoration: InputDecoration(
                                    labelText: 'ID / CÓDIGO *',
                                    labelStyle: const TextStyle(color: Colors.white60, fontSize: 12),
                                    hintText: 'Ej. 1, 2, 3,...',
                                    hintStyle: const TextStyle(color: Colors.white24),
                                    prefixIcon: const Icon(Icons.person_pin_rounded, color: Color(0xFF38BDF8), size: 20),
                                    filled: true,
                                    fillColor: const Color(0xFF0F172A),
                                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                                  ),
                                  validator: (val) => (val == null || val.trim().isEmpty) ? 'Requerido' : null,
                                ),
                                const SizedBox(height: 10),
                                DropdownButtonFormField<String>(
                                  initialValue: item.eventName,
                                  dropdownColor: const Color(0xFF1E293B),
                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                                  decoration: InputDecoration(
                                    labelText: 'MEDICIÓN / VISITA',
                                    labelStyle: const TextStyle(color: Colors.white60, fontSize: 12),
                                    prefixIcon: const Icon(Icons.event_repeat_rounded, color: Color(0xFF38BDF8), size: 20),
                                    filled: true,
                                    fillColor: const Color(0xFF0F172A),
                                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                                  ),
                                  items: _eventOptions.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
                                  onChanged: (val) {
                                    if (val != null) _onMomentChanged(item, val);
                                  },
                                ),
                              ],
                            ),
                          );
                        },
                      ),

                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: _addParticipantField,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF38BDF8),
                          side: const BorderSide(color: Color(0xFF38BDF8)),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        ),
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('Añadir Otro Participante'),
                      ),

                      const SizedBox(height: 20),
                      TextFormField(
                        controller: _activityController,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16),
                        decoration: InputDecoration(
                          labelText: 'ACTIVIDAD INICIAL *',
                          labelStyle: const TextStyle(color: Color(0xFF38BDF8), fontSize: 13, fontWeight: FontWeight.bold),
                          hintText: 'Ej. 1',
                          prefixIcon: const Icon(Icons.pin_rounded, color: Color(0xFF38BDF8)),
                          filled: true,
                          fillColor: const Color(0xFF1E293B),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                        ),
                        validator: (value) {
                          final numVal = int.tryParse(value ?? '');
                          if (numVal == null || numVal < 1) return 'Debe ser mínimo 1';
                          return null;
                        },
                      ),

                      const SizedBox(height: 20),
                      SessionSetupCard(
                        protocols: _allProtocols,
                        battery: _sessionBattery,
                        modified: _batteryModified,
                        note: _setupNote,
                        loading: _loadingProtocols,
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

                      const SizedBox(height: 20),
                      TextFormField(
                        controller: _operatorController,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15),
                        decoration: InputDecoration(
                          labelText: 'EVALUADOR/A',
                          labelStyle: const TextStyle(color: Colors.white60, fontSize: 12),
                          hintText: 'Nombre o iniciales (va a REDCap y al manifiesto)',
                          hintStyle: const TextStyle(color: Colors.white24),
                          prefixIcon: const Icon(Icons.badge_rounded, color: Color(0xFF38BDF8), size: 20),
                          filled: true,
                          fillColor: const Color(0xFF1E293B),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E293B),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.folder_rounded, color: Color(0xFF38BDF8), size: 20),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'CARPETA DE LA SESIÓN',
                                    style: TextStyle(color: Colors.white60, fontSize: 12),
                                  ),
                                  const SizedBox(height: 2),
                                  AnimatedBuilder(
                                    animation: Listenable.merge([for (final p in _participants) p.controller]),
                                    builder: (context, _) => SelectableText(
                                      _folderPreview,
                                      style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  const Text(
                                    'Todo se guarda aquí mientras ocurre: marcas, Polar, vídeo y manifiesto para SAVES. '
                                    'Mejor un disco local (no una carpeta sincronizada).',
                                    style: TextStyle(color: Colors.white38, fontSize: 11),
                                  ),
                                ],
                              ),
                            ),
                            TextButton(onPressed: _chooseDataRoot, child: const Text('Cambiar')),
                          ],
                        ),
                      ),

                      const SizedBox(height: 28),
                      SizedBox(
                        width: double.infinity,
                        height: 54,
                        child: FilledButton.icon(
                          onPressed: _starting ? null : _submitAndStart,
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF38BDF8),
                            foregroundColor: Colors.black,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          ),
                          icon: const Icon(Icons.arrow_forward_rounded, size: 24),
                          label: Text(
                            'COMENZAR SESIÓN (${_participants.length} SUJETO${_participants.length > 1 ? 'S' : ''})',
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
