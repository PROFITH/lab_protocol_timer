import 'dart:async';

import 'package:flutter/material.dart';

import '../models/session_sensor.dart';
import '../session/session_clock.dart';
import '../session/session_controller.dart';
import 'calibration_program.dart';
import 'calibration_store.dart';
import 'dodecahedron.dart';
import '../ui/app_theme.dart';

Color get _accent => Palette.current.cyan;
Color get _card => Palette.current.surface;
Color get _warning => Palette.current.warn;

/// Calibration of the offline sensors, done by the technician alone before
/// the participants arrive or after they leave. The app says when to turn
/// the dodecahedron (beeps before each turn and the face number aloud),
/// shows the face that goes up and writes the times of each face in
/// `calibraciones/` under the data folder. Pops with the record when it is
/// complete, or null.
class CalibrationPage extends StatefulWidget {
  const CalibrationPage({
    super.key,
    required this.dataRoot,
    required this.audio,
    this.clock,
    this.program,
    this.initialDevices = const [],
  });

  final String dataRoot;

  /// Devices proposed for the dodecahedron (the serials typed for the
  /// participants, or the offline sensors of the protocol without serial).
  final List<CalibrationDevice> initialDevices;
  final SessionAudio audio;
  final SessionClock? clock;

  /// Fixed program (tests); null lets the technician choose 12 or 6 faces.
  final CalibrationProgram? program;

  @override
  State<CalibrationPage> createState() => _CalibrationPageState();
}

class _CalibrationPageState extends State<CalibrationPage> {
  late final SessionClock _clock = widget.clock ?? SystemSessionClock();
  int _faces = 12;
  CalibrationProgram? _program;
  CalibrationWriter? _writer;
  Duration _origin = Duration.zero;
  Timer? _ticker;
  CalibrationStep? _step;
  int _lastBeepSecond = -1;
  double _elapsed = 0;
  bool _done = false;

  /// Devices in the dodecahedron: type and serial being typed.
  late final List<(String, TextEditingController)> _devices = [
    for (final d in widget.initialDevices) (d.type, TextEditingController(text: d.serial)),
  ];

  static final _offlineTypes = [
    for (final t in sensorTypes)
      if (t.connection == 'offline' && t.key != 'other') t,
  ];

  List<CalibrationDevice> get _typedDevices => [
        for (final (type, c) in _devices)
          if (c.text.trim().isNotEmpty) CalibrationDevice(type, c.text.trim()),
      ];

  CalibrationProgram get _chosen => widget.program ?? CalibrationProgram(faces: _faces);

  @override
  void dispose() {
    _ticker?.cancel();
    for (final (_, c) in _devices) {
      c.dispose();
    }
    unawaited(widget.audio.dispose());
    super.dispose();
  }

  Future<void> _start() async {
    final devices = _typedDevices;
    if (devices.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Escribe el número de serie de los dispositivos que van en el dodecaedro.'),
      ));
      return;
    }
    final program = _chosen;
    final writer = await CalibrationWriter.create(widget.dataRoot, _clock.nowUtc());
    await writer.log('calibration_start', _clock.nowUtc(),
        detail: '${program.faces} caras; ${program.faceSeconds} s por cara');
    for (final d in devices) {
      await writer.log('device', _clock.nowUtc(), detail: d.code);
    }
    if (!mounted) {
      await writer.close();
      return;
    }
    setState(() {
      _program = program;
      _writer = writer;
      _origin = _clock.elapsed;
      _elapsed = 0;
      _step = null;
    });
    _tick();
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) => _tick());
  }

  /// Moves the calibration on; called every 100 ms (and by the tests).
  void _tick() {
    final program = _program;
    final writer = _writer;
    if (program == null || writer == null || _done) return;
    final now = _clock.nowUtc();
    final elapsed = (_clock.elapsed - _origin).inMilliseconds / 1000;
    final step = program.stepAt(elapsed);

    if (!identical(step, _step)) {
      final previous = _step;
      if (previous != null && previous.kind == CalibrationStepKind.face) {
        unawaited(writer.log('face_end', now, face: previous.face));
      }
      if (step == null) {
        _finish(now);
        return;
      }
      final event = switch (step.kind) {
        CalibrationStepKind.still => 'still_start',
        CalibrationStepKind.knock => 'knock_start',
        CalibrationStepKind.face => 'face_start',
      };
      unawaited(writer.log(event, now, face: step.face));
      if (previous != null) widget.audio.play(SessionSound.go);
      widget.audio.say(program.announcement(step));
    } else if (step != null) {
      // Beeps in the last seconds before the next change.
      final left = step.endSecond - elapsed;
      final second = step.endSecond - left.ceil();
      if (left <= CalibrationProgram.warningBeeps &&
          left > 0 &&
          second != _lastBeepSecond &&
          program.next(step) != null) {
        _lastBeepSecond = second;
        widget.audio.play(SessionSound.countdown);
      }
    }
    setState(() {
      _step = step;
      _elapsed = elapsed;
    });
  }

  Future<void> _finish(DateTime now) async {
    _done = true;
    _ticker?.cancel();
    final writer = _writer!;
    await writer.log('calibration_end', now);
    await writer.close();
    widget.audio.play(SessionSound.end);
    widget.audio.say('Calibración terminada.');
    final record = await CalibrationRecord.read(writer.file);
    if (!mounted) return;
    Navigator.of(context).pop(record);
  }

  Future<void> _cancel() async {
    if (_writer == null) {
      Navigator.of(context).pop();
      return;
    }
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('¿Cancelar la calibración?'),
        content: const Text(
          'Se guarda lo hecho hasta ahora, pero no contará como calibración '
          'completa. Habrá que repetirla.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Seguir calibrando'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Cancelar'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted || _done) return;
    _ticker?.cancel();
    final writer = _writer!;
    await writer.log('cancelled', _clock.nowUtc(), face: _step?.face);
    await writer.close();
    widget.audio.stopVoice();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_cancel());
      },
      child: Scaffold(
        backgroundColor: context.pal.panel,
        appBar: AppBar(
          title: const Text('Calibración'),
          leading: IconButton(icon: const Icon(Icons.close), onPressed: _cancel),
        ),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: _program == null ? _intro() : _running(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _intro() {
    final program = _chosen;
    final minutes = (program.totalSeconds / 60).ceil();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(child: DodecahedronView(face: 1, size: 220)),
        const SizedBox(height: 16),
        Card(
          color: _card,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Antes de que llegue el participante (o después de que se vaya)',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                for (final line in [
                  '1. Configura y pon a grabar todos los sensores offline (AX3, AX6, SENS, Matrix…).',
                  '2. Mételos en la espuma del dodecaedro y ciérralo.',
                  '3. Déjalo sobre una mesa firme con la cara 1 hacia arriba.',
                  '4. Pulsa «Empezar». A los ${program.stillSeconds} s, tres golpes secos; '
                      'después cada cara ${program.faceSeconds} s, de la 1 a la ${program.faces}.',
                  '5. Tres pitidos avisan de cada giro; al último gira y deja la cara que se dice hacia arriba. '
                      'No toques la mesa mientras está quieto.',
                ])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(line, style: const TextStyle(fontSize: 15, height: 1.35)),
                  ),
                const SizedBox(height: 8),
                Text(
                  'Dura unos $minutes min. Espera en ${CalibrationStore.folderOf(widget.dataRoot).path} '
                  'y, al empezar la sesión, pasa a la carpeta de los participantes cuyos sensores lleva.',
                  style: TextStyle(fontSize: 12, color: context.pal.on60),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        _devicesCard(),
        if (widget.program == null) ...[
          const SizedBox(height: 16),
          Center(
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 12, label: Text('Dodecaedro (12 caras)')),
                ButtonSegment(value: 6, label: Text('Caja rígida (6 caras)')),
              ],
              selected: {_faces},
              onSelectionChanged: (s) => setState(() => _faces = s.first),
            ),
          ),
        ],
        const SizedBox(height: 20),
        FilledButton.icon(
          key: const Key('calibration_start'),
          onPressed: _start,
          icon: const Icon(Icons.play_arrow),
          label: const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Text('EMPEZAR', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ),
        ),
      ],
    );
  }

  Widget _running() {
    final program = _program!;
    final step = _step;
    if (step == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final left = (step.endSecond - _elapsed).clamp(0, step.seconds).ceil();
    final next = program.next(step);
    final warning = left <= CalibrationProgram.warningBeeps && next != null;
    final faceIndex = step.kind == CalibrationStepKind.face ? step.face! : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          switch (step.kind) {
            CalibrationStepKind.still => 'CARA 1 ARRIBA, PREPÁRATE',
            CalibrationStepKind.knock => 'TRES GOLPES SECOS',
            CalibrationStepKind.face => 'CARA ${step.face} ARRIBA',
          },
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 34, fontWeight: FontWeight.w900, color: _accent),
        ),
        if (faceIndex != null)
          Text(
            'Cara $faceIndex de ${program.faces}',
            textAlign: TextAlign.center,
            style: TextStyle(color: context.pal.on60),
          ),
        const SizedBox(height: 12),
        Center(child: DodecahedronView(face: step.face ?? 1, size: 280)),
        const SizedBox(height: 12),
        Text(
          '$left s',
          key: const Key('calibration_left'),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 56,
            fontWeight: FontWeight.w900,
            color: warning ? _warning : context.pal.on,
          ),
        ),
        if (next != null)
          Text(
            warning
                ? 'Prepárate: ${_nextLabel(next)}'
                : 'Después: ${_nextLabel(next)}',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, color: warning ? _warning : context.pal.on70),
          ),
        const SizedBox(height: 16),
        Card(
          color: _card,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              program.instruction(step),
              style: const TextStyle(fontSize: 17, height: 1.35),
            ),
          ),
        ),
        const SizedBox(height: 12),
        LinearProgressIndicator(
          value: (_elapsed / program.totalSeconds).clamp(0.0, 1.0),
          minHeight: 6,
        ),
        const SizedBox(height: 4),
        Text(
          'Total: ${_mmss(_elapsed.floor())} de ${_mmss(program.totalSeconds)}',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: context.pal.on54),
        ),
      ],
    );
  }

  Widget _devicesCard() {
    return Card(
      color: _card,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'DISPOSITIVOS EN EL DODECAEDRO',
              style: TextStyle(fontSize: 12, color: context.pal.on60, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              'La calibración se guarda por número de serie: así cada sesión encuentra la de sus '
              'sensores. Si no caben todos, calibra en tandas.',
              style: TextStyle(fontSize: 12, color: context.pal.on54),
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < _devices.length; i++)
              Padding(
                key: ObjectKey(_devices[i].$2),
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 190,
                      child: DropdownButtonFormField<String>(
                        initialValue: _devices[i].$1,
                        isExpanded: true,
                        items: [
                          for (final t in _offlineTypes)
                            DropdownMenuItem(value: t.key, child: Text(t.label)),
                        ],
                        onChanged: (v) {
                          if (v != null) setState(() => _devices[i] = (v, _devices[i].$2));
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        key: Key('calibration_serial_$i'),
                        controller: _devices[i].$2,
                        decoration: const InputDecoration(hintText: 'Número de serie', isDense: true),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Quitar',
                      icon: const Icon(Icons.close_rounded, size: 18),
                      onPressed: () => setState(() => _devices.removeAt(i).$2.dispose()),
                    ),
                  ],
                ),
              ),
            TextButton.icon(
              onPressed: () => setState(() => _devices.add((
                    _devices.isEmpty ? 'ax3' : _devices.last.$1,
                    TextEditingController(),
                  ))),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Añadir dispositivo'),
            ),
          ],
        ),
      ),
    );
  }

  String _nextLabel(CalibrationStep next) => switch (next.kind) {
        CalibrationStepKind.still => 'cara 1 arriba',
        CalibrationStepKind.knock => 'tres golpes secos',
        CalibrationStepKind.face => 'gira a la cara ${next.face}',
      };

  static String _mmss(int s) =>
      '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
}
