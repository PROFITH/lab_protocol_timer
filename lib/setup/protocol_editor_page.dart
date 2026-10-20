import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../models/activity_battery.dart';
import '../services/compendium.dart';
import '../services/protocol_library.dart';
import 'setup_format.dart';

const _accent = Color(0xFF38BDF8);
const _card = Color(0xFF1E293B);
const _field = Color(0xFF0F172A);

InputDecoration _decoration(String label, {String? hint, String? helper}) =>
    InputDecoration(
      labelText: label,
      hintText: hint,
      helperText: helper,
      helperMaxLines: 2,
      labelStyle: const TextStyle(color: Colors.white60, fontSize: 13),
      hintStyle: const TextStyle(color: Colors.white24),
      helperStyle: const TextStyle(color: Colors.white38),
      filled: true,
      fillColor: _field,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
    );

/// Full-screen editor of the session protocol: activities (order, Compendium
/// code, durations) and sensors (type, placement, serial). Pops with the
/// edited [ActivityBattery], or null when cancelled.
class ProtocolEditorPage extends StatefulWidget {
  final ActivityBattery initial;

  /// Called after a protocol is saved under a new name, so the list of
  /// protocols on the setup screen can be refreshed.
  final ValueChanged<ActivityBattery>? onSaved;

  const ProtocolEditorPage({super.key, required this.initial, this.onSaved});

  @override
  State<ProtocolEditorPage> createState() => _ProtocolEditorPageState();
}

class _ProtocolEditorPageState extends State<ProtocolEditorPage> {
  late ActivityBattery _battery = widget.initial;
  late final List<BatteryActivity> _activities = [...widget.initial.activities];
  late final List<SessionSensor> _sensors = [...widget.initial.sensors];

  ActivityBattery get _edited =>
      _battery.copyWith(activities: [..._activities], sensors: [..._sensors]);

  Future<void> _editActivity([int? index]) async {
    final result = await showDialog<BatteryActivity>(
      context: context,
      builder: (_) => _ActivityDialog(
        initial: index == null ? null : _activities[index],
      ),
    );
    if (result == null) return;
    setState(() {
      if (index == null) {
        _activities.add(result);
      } else {
        _activities[index] = result;
      }
    });
  }

  Future<void> _editSensor([int? index]) async {
    final taken = [
      for (var i = 0; i < _sensors.length; i++)
        if (i != index) _sensors[i].sensorId,
    ];
    final result = await showDialog<SessionSensor>(
      context: context,
      builder: (_) => _SensorDialog(
        initial: index == null ? null : _sensors[index],
        takenIds: taken,
      ),
    );
    if (result == null) return;
    setState(() {
      if (index == null) {
        _sensors.add(result);
      } else {
        _sensors[index] = result;
      }
    });
  }

  Future<void> _saveAsProtocol() async {
    if (_activities.isEmpty) {
      _snack('Añade al menos una actividad antes de guardar.');
      return;
    }
    final controller = TextEditingController(
      text:
          _battery.protocolId.startsWith('custom_') ? _battery.displayName : '',
    );
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _card,
        title: const Text('Guardar como protocolo'),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: controller,
            autofocus: true,
            decoration: _decoration(
              'Nombre',
              hint: 'Ej. RUN4HEALTH v2',
              helper: 'Queda guardado en este ordenador. Con el mismo nombre '
                  'se sustituye la versión anterior.',
            ),
            onSubmitted: (value) => Navigator.of(context).pop(value),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty) return;

    final saved = _edited.copyWith(
      protocolId: protocolIdFromName(name),
      title: name.trim(),
      protocolVersion: '1',
    );
    await ProtocolLibrary.saveCustom(saved);
    if (!mounted) return;
    setState(() => _battery = saved);
    widget.onSaved?.call(saved);
    _snack('Protocolo «${saved.displayName}» guardado.');
  }

  Future<void> _exportJson() async {
    final location = await getSaveLocation(
      suggestedName: '${_battery.protocolId}.json',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Protocolo JSON', extensions: ['json']),
      ],
    );
    if (location == null) return;
    await File(location.path).writeAsString(
      const JsonEncoder.withIndent('  ').convert(_edited.toJson()),
    );
    if (!mounted) return;
    _snack('Exportado a ${location.path}');
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _apply() {
    if (_activities.isEmpty) {
      _snack('El protocolo necesita al menos una actividad.');
      return;
    }
    Navigator.of(context).pop(_edited);
  }

  @override
  Widget build(BuildContext context) {
    final total = _edited.plannedSeconds();
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: const Color(0xFF0B0F19),
        appBar: AppBar(
          backgroundColor: _card,
          title: Text(_battery.displayName),
          actions: [
            TextButton.icon(
              onPressed: _exportJson,
              icon: const Icon(Icons.file_download_outlined),
              label: const Text('Exportar JSON'),
            ),
            TextButton.icon(
              onPressed: _saveAsProtocol,
              icon: const Icon(Icons.save_outlined),
              label: const Text('Guardar como protocolo'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _apply,
              style: FilledButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: Colors.black,
              ),
              icon: const Icon(Icons.check_rounded),
              label: const Text('Usar en esta sesión'),
            ),
            const SizedBox(width: 12),
          ],
          bottom: TabBar(
            indicatorColor: _accent,
            labelColor: _accent,
            unselectedLabelColor: Colors.white60,
            tabs: [
              Tab(
                text: 'ACTIVIDADES (${_activities.length} · '
                    '${formatSeconds(total)})',
              ),
              Tab(text: 'SENSORES (${_sensors.length})'),
            ],
          ),
        ),
        body: TabBarView(
          children: [_buildActivities(), _buildSensors()],
        ),
      ),
    );
  }

  Widget _buildActivities() {
    return Column(
      children: [
        Expanded(
          child: ReorderableListView.builder(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
            itemCount: _activities.length,
            // onReorderItem only exists from Flutter 3.41.
            // ignore: deprecated_member_use
            onReorder: (from, to) => setState(() {
              if (to > from) to--;
              _activities.insert(to, _activities.removeAt(from));
            }),
            itemBuilder: (context, i) {
              final a = _activities[i];
              final details = [
                if (a.compendiumCode != null)
                  'Compendio ${a.compendiumCode}'
                      '${a.met == null ? '' : ' · ${formatDecimal(a.met)} MET'}',
                if (a.durationSeconds != null)
                  formatSeconds(a.durationSeconds!)
                else
                  'duración del Research Monitor',
                if (a.prepSeconds != null || a.postSeconds != null)
                  'estático ${a.prepSeconds ?? '–'} s / ${a.postSeconds ?? '–'} s',
                if (a.isCalibration) '${a.faces ?? 6} caras',
              ].join(' · ');
              return Card(
                key: ObjectKey(a),
                color: _card,
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: a.isCalibration
                        ? const Color(0xFF7C3AED)
                        : _accent.withAlpha(60),
                    foregroundColor: Colors.white,
                    child: a.isCalibration
                        ? const Icon(Icons.inventory_2_outlined, size: 20)
                        : Text('${i + 1}'),
                  ),
                  title: Text(a.name),
                  subtitle: Text(
                    a.notes == null ? details : '$details\n${a.notes}',
                    style: const TextStyle(color: Colors.white54),
                  ),
                  isThreeLine: a.notes != null,
                  onTap: () => _editActivity(i),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Duplicar',
                        icon: const Icon(Icons.copy_rounded, size: 20),
                        onPressed: () => setState(
                            () => _activities.insert(i + 1, a.copyWith())),
                      ),
                      IconButton(
                        tooltip: 'Eliminar',
                        icon: const Icon(Icons.delete_outline,
                            color: Colors.redAccent, size: 20),
                        onPressed: () =>
                            setState(() => _activities.removeAt(i)),
                      ),
                      const SizedBox(width: 32),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          child: Row(
            children: [
              OutlinedButton.icon(
                onPressed: () => _editActivity(),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Añadir actividad'),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: () => setState(
                  () => _activities.add(const BatteryActivity(
                    name: 'Caja de calibración',
                    kind: ActivityKind.calibration,
                    durationSeconds: 360,
                    prepSeconds: 120,
                    postSeconds: 30,
                    faces: 6,
                  )),
                ),
                icon: const Icon(Icons.inventory_2_outlined),
                label: const Text('Añadir caja de calibración'),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Arrastra para cambiar el orden. Toca una actividad para editarla.',
                  textAlign: TextAlign.right,
                  style: TextStyle(color: Colors.white38),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSensors() {
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
            itemCount: _sensors.length,
            itemBuilder: (context, i) {
              final s = _sensors[i];
              final details = [
                s.sensorId,
                if (s.hasSerial) 'nº ${s.serial}' else 'sin nº de serie',
                if (s.samplingRateHz != null)
                  '${formatDecimal(s.samplingRateHz)} Hz',
                if (s.rangeG != null) '±${formatDecimal(s.rangeG)} g',
                if (s.freeLiving) 'sigue en vida libre',
                if (s.connection == 'live') 'en directo',
              ].join(' · ');
              return Card(
                color: _card,
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: Icon(
                    switch (s.connection) {
                      'video' => Icons.videocam_outlined,
                      'live' => Icons.bluetooth_connected_rounded,
                      _ => Icons.watch_outlined,
                    },
                    color: _accent,
                  ),
                  title: Text(
                      '${s.deviceName} · ${s.placementLabel ?? 'sin ubicación'}'),
                  subtitle: Text(
                    details,
                    style: TextStyle(
                      color: s.hasSerial || s.connection == 'video'
                          ? Colors.white54
                          : const Color(0xFFFBBF24),
                    ),
                  ),
                  onTap: () => _editSensor(i),
                  trailing: IconButton(
                    tooltip: 'Eliminar',
                    icon: const Icon(Icons.delete_outline,
                        color: Colors.redAccent, size: 20),
                    onPressed: () => setState(() => _sensors.removeAt(i)),
                  ),
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          child: Row(
            children: [
              OutlinedButton.icon(
                onPressed: () => _editSensor(),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Añadir sensor'),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Los sensores van al session_manifest.json con su ubicación y '
                  'número de serie. El ID se usa también en el nombre de los archivos.',
                  textAlign: TextAlign.right,
                  style: TextStyle(color: Colors.white38),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Add or edit one activity.
class _ActivityDialog extends StatefulWidget {
  final BatteryActivity? initial;

  const _ActivityDialog({this.initial});

  @override
  State<_ActivityDialog> createState() => _ActivityDialogState();
}

class _ActivityDialogState extends State<_ActivityDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.initial?.name);
  late final _duration = TextEditingController(
    text: widget.initial?.durationSeconds == null
        ? ''
        : formatSeconds(widget.initial!.durationSeconds!),
  );
  late final _prep =
      TextEditingController(text: widget.initial?.prepSeconds?.toString());
  late final _post =
      TextEditingController(text: widget.initial?.postSeconds?.toString());
  late final _faces =
      TextEditingController(text: (widget.initial?.faces ?? 6).toString());
  late final _notes = TextEditingController(text: widget.initial?.notes);
  late final _instructions =
      TextEditingController(text: widget.initial?.instructions);
  late String? _animation = widget.initial?.animation;
  late ActivityKind _kind = widget.initial?.kind ?? ActivityKind.activity;
  late String? _code = widget.initial?.compendiumCode;
  late double? _met = widget.initial?.met;
  String? _codeDescription;

  @override
  void initState() {
    super.initState();
    Compendium.load().then((c) {
      if (!mounted) return;
      setState(() => _codeDescription = c.byCode(_code)?.description);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    for (final c in [_name, _duration, _prep, _post, _faces, _notes, _instructions]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickCompendium() async {
    final entry = await showDialog<CompendiumEntry>(
      context: context,
      builder: (_) => const CompendiumSearchDialog(),
    );
    if (entry == null) return;
    setState(() {
      _code = entry.code;
      _met = entry.met;
      _codeDescription = entry.description;
      if (_name.text.trim().isEmpty) _name.text = entry.description;
    });
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final notes = _notes.text.trim();
    final instructions = _instructions.text.trim();
    final calibration = _kind == ActivityKind.calibration;
    final duration = parseSeconds(_duration.text);
    final prep = parseSeconds(_prep.text);
    final post = parseSeconds(_post.text);
    // copyWith keeps what this dialog does not show (REDCap fields, resting
    // heart rate).
    Navigator.of(context).pop(
      (widget.initial ?? const BatteryActivity(name: '')).copyWith(
        name: _name.text.trim(),
        kind: _kind,
        compendiumCode: calibration ? null : _code,
        met: calibration ? null : _met,
        clearCompendium: calibration || _code == null,
        durationSeconds: duration,
        clearDuration: duration == null,
        prepSeconds: prep,
        clearPrep: prep == null,
        postSeconds: post,
        clearPost: post == null,
        faces: calibration ? int.tryParse(_faces.text.trim()) : null,
        clearFaces: !calibration,
        notes: notes.isEmpty ? null : notes,
        clearNotes: notes.isEmpty,
        instructions: instructions.isEmpty ? null : instructions,
        clearInstructions: instructions.isEmpty,
        animation: _animation,
        clearAnimation: _animation == null,
      ),
    );
  }

  String? _optionalSeconds(String? value, {bool allowZero = true}) {
    if (value == null || value.trim().isEmpty) return null;
    final seconds = parseSeconds(value);
    if (seconds == null || (!allowZero && seconds == 0)) {
      return 'Segundos o m:ss';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final calibration = _kind == ActivityKind.calibration;
    return AlertDialog(
      backgroundColor: _card,
      title:
          Text(widget.initial == null ? 'Nueva actividad' : 'Editar actividad'),
      content: SizedBox(
        width: 560,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SegmentedButton<ActivityKind>(
                  segments: const [
                    ButtonSegment(
                      value: ActivityKind.activity,
                      label: Text('Actividad'),
                      icon: Icon(Icons.directions_run_rounded),
                    ),
                    ButtonSegment(
                      value: ActivityKind.calibration,
                      label: Text('Caja de calibración'),
                      icon: Icon(Icons.inventory_2_outlined),
                    ),
                  ],
                  selected: {_kind},
                  onSelectionChanged: (s) => setState(() => _kind = s.first),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _name,
                  decoration: _decoration(
                    'Nombre (se lee en voz alta)',
                  ),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Requerido' : null,
                ),
                const SizedBox(height: 12),
                if (!calibration)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _field,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _code == null
                                ? 'Sin código del Compendio'
                                : 'Compendio $_code · ${formatDecimal(_met)} MET'
                                    '${_codeDescription == null ? '' : '\n$_codeDescription'}',
                            style: TextStyle(
                              color:
                                  _code == null ? Colors.white38 : Colors.white,
                            ),
                          ),
                        ),
                        if (_code != null)
                          IconButton(
                            tooltip: 'Quitar código',
                            icon: const Icon(Icons.close_rounded, size: 18),
                            onPressed: () => setState(() {
                              _code = null;
                              _met = null;
                              _codeDescription = null;
                            }),
                          ),
                        TextButton.icon(
                          onPressed: _pickCompendium,
                          icon: const Icon(Icons.search_rounded),
                          label: const Text('Buscar en el Compendio'),
                        ),
                      ],
                    ),
                  ),
                if (!calibration) const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _duration,
                        decoration: _decoration(
                          calibration ? 'Duración de las caras' : 'Duración',
                          hint: 'm:ss',
                          helper: 'Vacío: la del Research Monitor',
                        ),
                        validator: (v) => _optionalSeconds(v, allowZero: false),
                      ),
                    ),
                    if (calibration) ...[
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 110,
                        child: TextFormField(
                          controller: _faces,
                          decoration: _decoration('Caras'),
                          validator: (v) {
                            final n = int.tryParse(v?.trim() ?? '');
                            return n == null || n < 1 ? 'Mínimo 1' : null;
                          },
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _prep,
                        decoration: _decoration(
                          'Estático inicial (s)',
                          helper: 'Vacío: Research Monitor',
                        ),
                        validator: _optionalSeconds,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _post,
                        decoration: _decoration(
                          'Estático final (s)',
                          helper: 'Vacío: Research Monitor',
                        ),
                        validator: _optionalSeconds,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _notes,
                  maxLines: 2,
                  decoration: _decoration(
                    'Notas para el evaluador (no se leen)',
                    hint: 'Material, velocidad, carga...',
                  ),
                ),
                if (!calibration) ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _instructions,
                    maxLines: 2,
                    decoration: _decoration(
                      'Instrucciones para el participante',
                      hint: 'Se muestran en la pantalla del cronómetro',
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String?>(
                    initialValue: _animation,
                    decoration: _decoration('Figura en pantalla'),
                    items: [
                      DropdownMenuItem<String?>(
                        value: null,
                        child: Text(
                          'Automática (${animationLabels[guessAnimation(_name.text)]})',
                        ),
                      ),
                      for (final key in activityAnimations)
                        DropdownMenuItem<String?>(
                          value: key,
                          child: Text(animationLabels[key] ?? key),
                        ),
                    ],
                    onChanged: (value) => setState(() => _animation = value),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Aceptar')),
      ],
    );
  }
}

/// Search box over the whole 2024 Compendium.
class CompendiumSearchDialog extends StatefulWidget {
  const CompendiumSearchDialog({super.key});

  @override
  State<CompendiumSearchDialog> createState() => _CompendiumSearchDialogState();
}

class _CompendiumSearchDialogState extends State<CompendiumSearchDialog> {
  Compendium? _compendium;
  String? _error;
  String _query = '';

  @override
  void initState() {
    super.initState();
    Compendium.load().then((c) {
      if (mounted) setState(() => _compendium = c);
    }).catchError((Object e) {
      if (mounted) setState(() => _error = '$e');
    });
  }

  @override
  Widget build(BuildContext context) {
    final results = _compendium?.search(_query) ?? const <CompendiumEntry>[];
    return AlertDialog(
      backgroundColor: _card,
      title: const Text('Compendio de Actividades Físicas 2024'),
      content: SizedBox(
        width: 680,
        height: 520,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: _decoration(
                'Buscar',
                hint: 'Ej. caminar cinta, barrer, 17200',
              ).copyWith(prefixIcon: const Icon(Icons.search_rounded)),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _error != null
                  ? Text('No se pudo cargar el Compendio: $_error')
                  : _compendium == null
                      ? const Center(child: CircularProgressIndicator())
                      : ListView.builder(
                          itemCount: results.length,
                          itemBuilder: (context, i) {
                            final e = results[i];
                            return ListTile(
                              dense: true,
                              leading: Text(
                                e.code,
                                style: const TextStyle(
                                  fontFeatures: [FontFeature.tabularFigures()],
                                  color: _accent,
                                ),
                              ),
                              title: Text(e.description),
                              subtitle: Text(
                                e.heading,
                                style: const TextStyle(color: Colors.white38),
                              ),
                              trailing: Text('${formatDecimal(e.met)} MET'),
                              onTap: () => Navigator.of(context).pop(e),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
      ],
    );
  }
}

/// Add or edit one sensor.
class _SensorDialog extends StatefulWidget {
  final SessionSensor? initial;
  final List<String> takenIds;

  const _SensorDialog({this.initial, required this.takenIds});

  @override
  State<_SensorDialog> createState() => _SensorDialogState();
}

class _SensorDialogState extends State<_SensorDialog> {
  final _formKey = GlobalKey<FormState>();
  late String _type = widget.initial?.type ?? 'ax3';
  late String? _placement =
      sensorPlacementByKey(widget.initial?.placement)?.key ??
          (widget.initial == null ? 'wrist' : null);
  late String? _dominance = widget.initial == null
      ? SensorDominance.nonDominant
      : widget.initial!.dominance;
  late String? _side = widget.initial?.side;
  late bool _freeLiving = widget.initial?.freeLiving ?? false;
  late final _id = TextEditingController(
    text: widget.initial?.sensorId ?? _suggestedId(),
  );
  late final _serial = TextEditingController(text: widget.initial?.serial);
  late final _rate = TextEditingController(
    text: formatDecimal(
      widget.initial == null
          ? sensorTypeByKey(_type).defaultSamplingRateHz
          : widget.initial!.samplingRateHz,
    ),
  );
  late final _range = TextEditingController(
    text: formatDecimal(
      widget.initial == null
          ? sensorTypeByKey(_type).defaultRangeG
          : widget.initial!.rangeG,
    ),
  );

  /// The ID follows type and placement until the user types one.
  late bool _idEdited = widget.initial != null &&
      widget.initial!.sensorId !=
          SessionSensor.suggestId(
            widget.initial!.type,
            widget.initial!.placement,
            dominance: widget.initial!.dominance,
            side: widget.initial!.side,
            taken: widget.takenIds,
          );

  String _suggestedId() => SessionSensor.suggestId(
        _type,
        _placement,
        dominance: _dominance,
        side: _side,
        taken: widget.takenIds,
      );

  @override
  void dispose() {
    for (final c in [_id, _serial, _rate, _range]) {
      c.dispose();
    }
    super.dispose();
  }

  void _typeOrPlacementChanged() {
    if (!_idEdited) {
      _id.text = _suggestedId();
    }
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final serial = _serial.text.trim();
    final base = widget.initial;
    Navigator.of(context).pop(
      SessionSensor(
        sensorId: _id.text.trim(),
        type: _type,
        placement: _placement ?? base?.placement,
        dominance: _dominance,
        side: _side,
        serial: serial.isEmpty ? null : serial,
        samplingRateHz: parseDecimal(_rate.text),
        rangeG: parseDecimal(_range.text),
        freeLiving: _freeLiving,
        deviceNameOverride: _type == 'other' ? base?.deviceNameOverride : null,
        timestampDomainOverride:
            _type == base?.type ? base?.timestampDomainOverride : null,
      ),
    );
  }

  String? _optionalPositive(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final n = parseDecimal(value);
    return n == null || n <= 0 ? 'Número positivo' : null;
  }

  @override
  Widget build(BuildContext context) {
    final type = sensorTypeByKey(_type);
    final isCamera = type.connection == 'video';
    return AlertDialog(
      backgroundColor: _card,
      title: Text(widget.initial == null ? 'Nuevo sensor' : 'Editar sensor'),
      content: SizedBox(
        width: 520,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: _type,
                  dropdownColor: _card,
                  decoration: _decoration('Tipo'),
                  items: [
                    for (final t in sensorTypes)
                      DropdownMenuItem(value: t.key, child: Text(t.label)),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() {
                      _type = v;
                      final t = sensorTypeByKey(v);
                      _rate.text = formatDecimal(t.defaultSamplingRateHz);
                      _range.text = formatDecimal(t.defaultRangeG);
                      if (t.connection == 'video') {
                        _placement = 'room';
                        _dominance = null;
                        _side = null;
                      }
                      _typeOrPlacementChanged();
                    });
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _placement,
                  dropdownColor: _card,
                  decoration: _decoration(
                    'Ubicación',
                    helper:
                        _placement == null && widget.initial?.placement != null
                            ? 'Ahora: ${widget.initial!.placement}'
                            : null,
                  ),
                  items: [
                    for (final p in sensorPlacements)
                      DropdownMenuItem(value: p.key, child: Text(p.label)),
                  ],
                  onChanged: (v) => setState(() {
                    _placement = v;
                    _typeOrPlacementChanged();
                  }),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String?>(
                        key: const ValueKey('sensor_dominance'),
                        initialValue: _dominance,
                        dropdownColor: _card,
                        decoration: _decoration('Dominancia',
                            helper: 'Vacío si no aplica'),
                        items: [
                          const DropdownMenuItem(value: null, child: Text('—')),
                          for (final d in SensorDominance.values)
                            DropdownMenuItem(
                                value: d,
                                child: Text(SensorDominance.labels[d]!)),
                        ],
                        onChanged: (v) => setState(() {
                          _dominance = v;
                          _typeOrPlacementChanged();
                        }),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<String?>(
                        key: const ValueKey('sensor_side'),
                        initialValue: _side,
                        dropdownColor: _card,
                        decoration:
                            _decoration('Lado', helper: 'Vacío si no aplica'),
                        items: [
                          const DropdownMenuItem(value: null, child: Text('—')),
                          for (final side in SensorSide.values)
                            DropdownMenuItem(
                                value: side,
                                child: Text(SensorSide.labels[side]!)),
                        ],
                        onChanged: (v) => setState(() {
                          _side = v;
                          _typeOrPlacementChanged();
                        }),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _serial,
                  decoration: _decoration('Número de serie'),
                ),
                const SizedBox(height: 12),
                if (!isCamera)
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _rate,
                          decoration: _decoration('Frecuencia (Hz)',
                              helper: 'Opcional'),
                          validator: _optionalPositive,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextFormField(
                          controller: _range,
                          decoration:
                              _decoration('Rango (±g)', helper: 'Opcional'),
                          validator: _optionalPositive,
                        ),
                      ),
                    ],
                  ),
                if (!isCamera) const SizedBox(height: 12),
                TextFormField(
                  controller: _id,
                  decoration: _decoration(
                    'ID del sensor',
                    helper: 'Clave en el manifiesto y en el nombre de los '
                        'archivos (R4H_03_D0_<ID>.cwa).',
                  ),
                  onChanged: (_) => _idEdited = true,
                  validator: (v) {
                    final id = v?.trim() ?? '';
                    if (id.isEmpty) return 'Requerido';
                    if (!RegExp(r'^[A-Za-z0-9_\-]+$').hasMatch(id)) {
                      return 'Solo letras, números, - y _';
                    }
                    if (widget.takenIds.contains(id)) return 'Ya existe';
                    return null;
                  },
                ),
                if (!isCamera)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _freeLiving,
                    onChanged: (v) => setState(() => _freeLiving = v),
                    title: const Text('Sigue puesto en vida libre'),
                    subtitle: const Text(
                      'No se quita al terminar la visita',
                      style: TextStyle(color: Colors.white38),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Aceptar')),
      ],
    );
  }
}
