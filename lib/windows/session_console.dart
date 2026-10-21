import 'package:flutter/material.dart';

import '../models/activity_battery.dart';
import 'monitor_session.dart';

const _card = Color(0xFF111827);
const _cardBorder = Colors.white12;
const _accent = Color(0xFF38BDF8);
const _amber = Color(0xFFFBBF24);
const _green = Color(0xFF34D399);
const _red = Color(0xFFF87171);
const _muted = Colors.white54;

/// Colour and label of each phase for the evaluator.
({String label, Color color}) phaseLook(String phase) => switch (phase) {
      'static_prep' => (label: 'QUIETO · ANTES', color: _amber),
      'activity_main' => (label: 'ACTIVIDAD', color: _green),
      'static_post' => (label: 'QUIETO · DESPUÉS', color: _red),
      _ => (label: 'DESCANSO', color: _accent),
    };

/// A device of the session in the status strip of the console.
class DeviceChip {
  const DeviceChip({
    required this.label,
    required this.detail,
    required this.color,
    required this.icon,
    this.onTap,
    this.warning = false,
  });

  final String label;
  final String detail;
  final Color color;
  final IconData icon;
  final VoidCallback? onTap;

  /// Something the evaluator should look at (a sensor lost during the
  /// session, a camera that does not record).
  final bool warning;
}

/// Something checked before starting the session.
class PreflightItem {
  const PreflightItem(this.label, this.ok, this.detail, {this.isCamera = false, this.manual = false});

  final String label;
  final bool ok;
  final String detail;

  /// A camera: without it the session can still start without video.
  final bool isCamera;

  /// Only the evaluator can check it (a sensor that records on its own).
  final bool manual;
}

/// Asks the evaluator to confirm an action.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirm,
  bool danger = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: const Color(0xFF1E293B),
      title: Text(title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Text(message, style: const TextStyle(color: Colors.white70, height: 1.4)),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Volver')),
        FilledButton(
          autofocus: true,
          style: danger ? FilledButton.styleFrom(backgroundColor: Colors.redAccent) : null,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirm),
        ),
      ],
    ),
  );
  return result == true;
}

// =============================================================================
// Console: what is happening and the controls
// =============================================================================

class SessionConsole extends StatelessWidget {
  const SessionConsole({
    super.key,
    required this.session,
    required this.send,
    required this.onStart,
    this.devices = const [],
    this.recording = false,
    this.onOpenFolder,
    this.onSettings,
  });

  final MonitorSession session;
  final SessionCommandSender send;

  /// Runs the checks before the start and starts the session.
  final Future<void> Function() onStart;
  final List<DeviceChip> devices;

  /// A camera is recording.
  final bool recording;
  final void Function(String path)? onOpenFolder;
  final VoidCallback? onSettings;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) => Container(
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _cardBorder),
        ),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _StatusRow(session: session, recording: recording, onOpenFolder: onOpenFolder),
            const SizedBox(height: 12),
            _Controls(session: session, send: send, onStart: onStart, onSettings: onSettings),
            if (session.notice != null || session.storeError != null) ...[
              const SizedBox(height: 8),
              _NoticeLine(session: session),
            ],
            if (devices.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [for (final d in devices) _DeviceChipView(chip: d)],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.session, required this.recording, this.onOpenFolder});

  final MonitorSession session;
  final bool recording;
  final void Function(String path)? onOpenFolder;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final look = phaseLook(s.phase);
    final count = s.activityCount;
    final started = !s.isIdle;

    final (statusText, statusColor) = switch (s.status) {
      'running' => ('EN CURSO', _green),
      'paused' => ('EN PAUSA', _amber),
      'finished' || 'finishing' => ('GUARDANDO...', _accent),
      'saved' => ('GUARDADA', _accent),
      'cancelled' => ('CANCELADA', _red),
      _ => (s.resumed ? 'RECUPERADA: PULSA EMPEZAR' : 'SIN EMPEZAR', Colors.white54),
    };

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Participant
        Expanded(
          flex: 3,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                [if (s.study != null) s.study!, s.visit].where((t) => t.isNotEmpty).join(' · ').toUpperCase(),
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Colors.white38, letterSpacing: 1.1),
              ),
              const SizedBox(height: 2),
              Text(
                'Participante ${s.participants}',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Colors.white),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  if (s.operator != null)
                    Flexible(
                      child: Text(
                        'Evaluador: ${s.operator}',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: _muted),
                      ),
                    ),
                  if (s.sessionDir != null) ...[
                    if (s.operator != null) const SizedBox(width: 10),
                    Flexible(
                      child: Tooltip(
                        message: '${s.sessionDir}\nClic: abrir la carpeta',
                        child: InkWell(
                          onTap: onOpenFolder == null ? null : () => onOpenFolder!(s.sessionDir!),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.folder_open_rounded, size: 14, color: _accent),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  _shortPath(s.sessionDir!),
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 12, color: _accent),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
        Container(width: 1, height: 54, color: Colors.white12),
        const SizedBox(width: 16),
        // Activity
        Expanded(
          flex: 5,
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          started
                              ? count > 0
                                  ? 'ACTIVIDAD ${s.isWait ? (s.nextIndex ?? s.activityIndex) : s.activityIndex} DE $count'
                                  : 'ACTIVIDAD ${s.activityIndex}'
                              : 'PRIMERA ACTIVIDAD',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: Colors.white38,
                            letterSpacing: 1.1,
                          ),
                        ),
                        if (started && !s.isClosing) ...[
                          const SizedBox(width: 8),
                          _Pill(text: s.isPaused ? 'PAUSA' : look.label, color: s.isPaused ? _amber : look.color),
                        ],
                        if (s.attempt > 1 && !s.isWait) ...[
                          const SizedBox(width: 6),
                          _Pill(text: 'INTENTO ${s.attempt}', color: Colors.white70),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      s.isWait
                          ? s.protocolComplete
                              ? 'Protocolo completado'
                              : 'Siguiente: ${s.nextName ?? s.nameOf(s.nextIndex ?? s.activityIndex + 1)}'
                          : s.activityName,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Colors.white),
                    ),
                    if (!s.isWait && started && s.nextName != null && !s.isClosing)
                      Text(
                        'Después: ${s.nextName}',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: _muted),
                      ),
                  ],
                ),
              ),
              if (started && !s.isClosing) _PhaseClock(session: s, color: s.isPaused ? _amber : look.color),
            ],
          ),
        ),
        Container(width: 1, height: 54, color: Colors.white12),
        const SizedBox(width: 16),
        // Session
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Text(
                  statusText,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: statusColor, letterSpacing: 0.5),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              formatClock(s.sessionElapsedSeconds),
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w900,
                color: Colors.white,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (recording) ...[
                  const Icon(Icons.fiber_manual_record, size: 12, color: Colors.redAccent),
                  const SizedBox(width: 3),
                  const Text('REC', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Colors.redAccent)),
                  const SizedBox(width: 10),
                ] else if (started && s.video && !s.isClosing) ...[
                  const Icon(Icons.videocam_off_rounded, size: 13, color: _amber),
                  const SizedBox(width: 3),
                  const Text('SIN VÍDEO', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: _amber)),
                  const SizedBox(width: 10),
                ],
                Tooltip(
                  message: 'Ventanas de sincronización registradas',
                  child: Text(
                    '${s.syncCount} sinc.',
                    style: const TextStyle(fontSize: 11, color: _muted, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  static String _shortPath(String path) {
    final parts = path.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty).toList();
    if (parts.length <= 3) return path;
    return '…/${parts.sublist(parts.length - 3).join('/')}';
  }
}

class _PhaseClock extends StatelessWidget {
  const _PhaseClock({required this.session, required this.color});

  final MonitorSession session;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final planned = s.plannedSeconds;
    final counting = planned != null && planned > 0;
    final value = s.isWait
        ? formatClock(s.elapsedPhaseSeconds)
        : counting
            ? formatClock(s.remainingSeconds)
            : formatClock(s.elapsedPhaseSeconds);
    final progress = counting && !s.isWait ? (1 - s.remainingSeconds / planned).clamp(0.0, 1.0) : null;
    return SizedBox(
      width: 120,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            s.isWait ? 'DESCANSANDO' : (counting ? 'QUEDAN' : 'LLEVA'),
            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Colors.white38, letterSpacing: 1),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 30,
              height: 1.1,
              fontWeight: FontWeight.w900,
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          if (progress != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 5,
                  color: color,
                  backgroundColor: Colors.white10,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Text(
          text,
          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: color, letterSpacing: 0.6),
        ),
      );
}

class _NoticeLine extends StatelessWidget {
  const _NoticeLine({required this.session});

  final MonitorSession session;

  @override
  Widget build(BuildContext context) {
    final error = session.storeError;
    final text = error != null ? 'No se pudo escribir en la carpeta: $error' : session.notice!;
    final color = error != null ? _red : _amber;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(error != null ? Icons.error_rounded : Icons.info_rounded, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w600))),
        ],
      ),
    );
  }
}

class _DeviceChipView extends StatelessWidget {
  const _DeviceChipView({required this.chip});

  final DeviceChip chip;

  @override
  Widget build(BuildContext context) {
    final c = chip;
    return Tooltip(
      message: c.onTap == null ? c.detail : '${c.detail}\nClic: conectar o revisar',
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: c.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: c.warning ? c.color.withValues(alpha: 0.18) : const Color(0xFF0B1220),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: c.color.withValues(alpha: c.warning ? 0.9 : 0.45), width: c.warning ? 1.5 : 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(c.icon, size: 14, color: c.color),
              const SizedBox(width: 6),
              Text(c.label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Colors.white)),
              const SizedBox(width: 6),
              Text(c.detail, style: TextStyle(fontSize: 12, color: c.color, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.session, required this.send, required this.onStart, this.onSettings});

  final MonitorSession session;
  final SessionCommandSender send;
  final Future<void> Function() onStart;
  final VoidCallback? onSettings;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final started = !s.isIdle;
    final closing = s.isClosing;

    // Primary: start, pause, resume.
    final Widget primary;
    if (!started) {
      primary = _BigButton(
        label: 'EMPEZAR SESIÓN',
        shortcut: 'F5',
        icon: Icons.play_arrow_rounded,
        color: _green,
        onPressed: onStart,
      );
    } else if (s.isPaused) {
      primary = _BigButton(
        label: 'REANUDAR',
        shortcut: 'F5',
        icon: Icons.play_arrow_rounded,
        color: _green,
        onPressed: () => send('resume'),
      );
    } else {
      primary = _BigButton(
        label: switch (s.status) {
          'saved' => 'GUARDADA',
          'cancelled' => 'CANCELADA',
          _ => closing ? 'GUARDANDO' : 'PAUSA',
        },
        shortcut: 'F5',
        icon: Icons.pause_rounded,
        color: _amber,
        onPressed: closing ? null : () => send('pause'),
      );
    }

    final next = nextAction(s);

    return Row(
      children: [
        primary,
        const SizedBox(width: 10),
        Expanded(
          flex: 3,
          child: _BigButton(
            label: next.label,
            shortcut: 'F6',
            icon: Icons.skip_next_rounded,
            color: _accent,
            tooltip: next.tooltip,
            expand: true,
            onPressed: next.enabled ? () => runNext(context, s, send) : null,
          ),
        ),
        const SizedBox(width: 10),
        Tooltip(
          message: closing
              ? 'Disponible con la sesión en marcha'
              : s.syncAvailable
                  ? 'Cuenta atrás de 3 s y ${s.syncKind == 'jump' ? 'salto' : 'palmada'} del participante'
                  : (s.syncReason ?? 'No disponible'),
          child: _BigButton(
            label: s.syncKind == 'jump' ? 'SALTO' : 'PALMADA',
            shortcut: 'F7',
            icon: Icons.sync_rounded,
            color: const Color(0xFFA78BFA),
            onPressed: s.syncAvailable && !closing ? () => send('sync') : null,
          ),
        ),
        const SizedBox(width: 10),
        _SmallButton(
          tooltip: 'Repetir la actividad desde la fase estática',
          icon: Icons.replay_rounded,
          label: 'Repetir',
          onPressed: started && !closing && !s.isWait ? () => _repeat(context, s, send) : null,
        ),
        const SizedBox(width: 6),
        _SmallButton(
          tooltip: s.isWait ? 'Saltar la siguiente actividad' : 'Saltar esta actividad (solo antes de empezarla)',
          icon: Icons.redo_rounded,
          label: 'Saltar',
          onPressed: started && !closing && (s.phase == 'static_prep' || (s.isWait && !s.protocolComplete))
              ? () => _skip(context, s, send)
              : null,
        ),
        const SizedBox(width: 6),
        _SmallButton(
          tooltip: s.voice ? 'Silenciar la voz (los pitidos siguen)' : 'Activar la voz',
          icon: s.voice ? Icons.volume_up_rounded : Icons.volume_off_rounded,
          label: s.voice ? 'Voz' : 'Sin voz',
          onPressed: closing ? null : () => send('voice', {'enabled': !s.voice}),
        ),
        const SizedBox(width: 6),
        _SmallButton(
          tooltip: 'Duración de las fases',
          icon: Icons.tune_rounded,
          label: 'Ajustes',
          onPressed: closing ? null : onSettings,
        ),
        const SizedBox(width: 10),
        _BigButton(
          label: 'FINALIZAR Y GUARDAR',
          icon: Icons.stop_rounded,
          color: s.protocolComplete ? _green : const Color(0xFFEF4444),
          filled: s.protocolComplete,
          onPressed: started && !closing ? () => confirmFinish(context, s, send) : null,
        ),
        const SizedBox(width: 6),
        IconButton(
          tooltip: 'Cancelar la sesión (no se envía a REDCap)',
          onPressed: started && !closing ? () => confirmCancel(context, s, send) : null,
          icon: const Icon(Icons.close_rounded),
          color: Colors.redAccent,
        ),
      ],
    );
  }

  static Future<void> _repeat(BuildContext context, MonitorSession s, SessionCommandSender send) async {
    final cut = s.isMain;
    final ok = await confirmAction(
      context,
      title: 'Repetir «${s.activityName}»',
      message: cut
          ? 'La actividad se corta ahora (queda como parcial) y vuelve a empezar desde la fase estática.'
          : 'La actividad vuelve a empezar desde la fase estática.',
      confirm: 'Repetir',
    );
    if (ok) await send('repeat');
  }

  static Future<void> _skip(BuildContext context, MonitorSession s, SessionCommandSender send) async {
    final index = s.isWait ? (s.nextIndex ?? s.activityIndex) : s.activityIndex;
    final ok = await confirmAction(
      context,
      title: 'Saltar «${s.nameOf(index)}»',
      message: 'Quedará como no realizada. Se puede volver a ella desde la lista de actividades.',
      confirm: 'Saltar',
    );
    if (ok) await send('skip');
  }
}

/// What the "next" button does in each phase.
({String label, String tooltip, bool enabled}) nextAction(MonitorSession s) {
  if (s.isIdle || s.isClosing) {
    return (label: 'SIGUIENTE', tooltip: 'Disponible con la sesión en marcha', enabled: false);
  }
  switch (s.phase) {
    case 'static_prep':
      return (
        label: 'EMPEZAR YA',
        tooltip: 'Termina la fase estática y empieza la actividad ahora',
        enabled: !s.isPaused,
      );
    case 'activity_main':
      final counting = (s.plannedSeconds ?? 0) > 0;
      return (
        label: counting ? 'TERMINAR ANTES' : 'TERMINAR ACTIVIDAD',
        tooltip: counting
            ? 'Termina la actividad antes de tiempo (queda como parcial)'
            : 'Termina la actividad y pasa a la fase estática',
        enabled: true,
      );
    case 'static_post':
      return (label: 'PASAR AL DESCANSO', tooltip: 'Termina la fase estática final', enabled: true);
    default:
      if (s.protocolComplete || s.nextIndex == null) {
        return (label: 'PROTOCOLO COMPLETADO', tooltip: 'Pulsa FINALIZAR Y GUARDAR', enabled: false);
      }
      return (
        label: 'EMPEZAR: ${s.nextName ?? s.nameOf(s.nextIndex!)}',
        tooltip: 'Empieza la siguiente actividad (fase estática, palmada y actividad)',
        enabled: true,
      );
  }
}

/// Runs the "next" action, asking first when it cuts an activity short.
Future<void> runNext(BuildContext context, MonitorSession s, SessionCommandSender send) async {
  if (!nextAction(s).enabled) return;
  if (s.isMain && (s.plannedSeconds ?? 0) > 0 && s.remainingSeconds > 1) {
    final ok = await confirmAction(
      context,
      title: 'Terminar «${s.activityName}» antes de tiempo',
      message: 'Quedan ${formatClock(s.remainingSeconds)}. La actividad quedará como parcial; '
          'se puede cambiar después en la lista de actividades.',
      confirm: 'Terminar ahora',
    );
    if (!ok) return;
  }
  await send('advance');
}

Future<void> confirmFinish(BuildContext context, MonitorSession s, SessionCommandSender send) async {
  final notes = TextEditingController(text: s.snap['notes']?.toString() ?? '');
  final missing = [for (final i in s.notDone) s.nameOf(i)];
  final pendingRpe = s.pendingRpeLog != null;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: const Color(0xFF1E293B),
      title: const Text('Finalizar y guardar la sesión'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (s.isMain)
              const _DialogWarning('La actividad en curso se corta y queda como parcial.'),
            if (missing.isNotEmpty)
              _DialogWarning('Sin hacer (${missing.length}): ${missing.join(', ')}.'),
            if (pendingRpe) const _DialogWarning('Falta el esfuerzo (RPE) de la última actividad.'),
            const Text(
              'Se paran la cámara y los Polar, se guarda todo en la carpeta de la sesión '
              'y se envía a REDCap.',
              style: TextStyle(color: Colors.white70, height: 1.4),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: notes,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'Notas de la sesión (opcional)',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Volver')),
        FilledButton.icon(
          onPressed: () => Navigator.of(context).pop(true),
          icon: const Icon(Icons.save_rounded),
          label: const Text('Finalizar y guardar'),
        ),
      ],
    ),
  );
  final text = notes.text.trim();
  notes.dispose();
  if (ok == true) await send('finish', {'notes': text});
}

Future<void> confirmCancel(BuildContext context, MonitorSession s, SessionCommandSender send) async {
  final reason = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: const Color(0xFF1E293B),
      title: const Text('Cancelar la sesión'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'No se envía nada a REDCap. Los archivos se guardan en una carpeta marcada '
              'como cancelada y la visita queda libre para empezarla de nuevo.',
              style: TextStyle(color: Colors.white70, height: 1.4),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: reason,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Motivo', border: OutlineInputBorder()),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('No cancelar')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Cancelar la sesión'),
        ),
      ],
    ),
  );
  final text = reason.text.trim();
  reason.dispose();
  if (ok == true) await send('cancel', {'reason': text});
}

class _DialogWarning extends StatelessWidget {
  const _DialogWarning(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.warning_amber_rounded, color: _amber, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: const TextStyle(color: _amber, fontWeight: FontWeight.w600))),
          ],
        ),
      );
}

class _BigButton extends StatelessWidget {
  const _BigButton({
    required this.label,
    required this.icon,
    required this.color,
    this.shortcut,
    this.tooltip,
    this.onPressed,
    this.expand = false,
    this.filled = true,
  });

  final String label;
  final IconData icon;
  final Color color;
  final String? shortcut;
  final String? tooltip;
  final VoidCallback? onPressed;
  final bool expand;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final child = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 22),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14, letterSpacing: 0.4),
          ),
        ),
        if (shortcut != null) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.black26),
            ),
            child: Text(shortcut!, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800)),
          ),
        ],
      ],
    );
    final style = filled
        ? FilledButton.styleFrom(
            backgroundColor: color,
            foregroundColor: Colors.black,
            disabledBackgroundColor: Colors.white10,
            disabledForegroundColor: Colors.white30,
            minimumSize: const Size(0, 52),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          )
        : null;
    final button = filled
        ? FilledButton(onPressed: onPressed, style: style, child: child)
        : OutlinedButton(
            onPressed: onPressed,
            style: OutlinedButton.styleFrom(
              foregroundColor: color,
              side: BorderSide(color: onPressed == null ? Colors.white12 : color),
              minimumSize: const Size(0, 52),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: child,
          );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

class _SmallButton extends StatelessWidget {
  const _SmallButton({required this.tooltip, required this.icon, required this.label, this.onPressed});

  final String tooltip;
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white,
            side: const BorderSide(color: Colors.white24),
            minimumSize: const Size(0, 52),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20),
              Text(label, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      );
}

// =============================================================================
// Activities: list, effort and the values typed for REDCap
// =============================================================================

class ActivityPanel extends StatefulWidget {
  const ActivityPanel({super.key, required this.session, required this.send});

  final MonitorSession session;
  final SessionCommandSender send;

  @override
  State<ActivityPanel> createState() => _ActivityPanelState();
}

class _ActivityPanelState extends State<ActivityPanel> {
  /// Activity whose editor is open.
  int? _open;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.session,
      builder: (context, _) {
        final s = widget.session;
        final count = s.activityCount;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (s.pendingRpeLog != null && s.logAt(s.pendingRpeLog!) != null)
              _BorgPicker(
                title: 'Esfuerzo de «${s.nameOf(s.logAt(s.pendingRpeLog!)!.activityIndex)}»',
                subtitle: 'El participante lo dice en voz alta (Borg 0-10)',
                onPick: (v) => widget.send('annotate', {'log_index': s.pendingRpeLog, 'rpe': v}),
              )
            else if (s.rpeBeforeFor != null)
              _BorgPicker(
                title: 'Esfuerzo ANTES de «${s.nameOf(s.rpeBeforeFor!)}»',
                subtitle: 'Cómo se siente ahora, antes de empezar (Borg 0-10)',
                onPick: (v) => widget.send('rpe_before', {'index': s.rpeBeforeFor, 'value': v}),
              ),
            Expanded(
              child: count == 0
                  ? _LogOnlyList(session: s, send: widget.send)
                  : ListView.builder(
                      itemCount: count,
                      itemBuilder: (context, i) => _ActivityRow(
                        index: i + 1,
                        session: s,
                        open: _open == i + 1,
                        onToggle: () => setState(() => _open = _open == i + 1 ? null : i + 1),
                        send: widget.send,
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _BorgPicker extends StatelessWidget {
  const _BorgPicker({required this.title, required this.subtitle, required this.onPick});

  final String title;
  final String subtitle;
  final ValueChanged<int> onPick;

  static const _labels = {
    0: 'Nada',
    1: 'Muy, muy suave',
    2: 'Suave',
    3: 'Moderado',
    4: 'Algo duro',
    5: 'Duro',
    7: 'Muy duro',
    9: 'Muy, muy duro',
    10: 'Máximo',
  };

  static Color colorOf(int v) => HSVColor.fromAHSV(1, (200 - v * 20).clamp(0, 200).toDouble(), 0.65, 0.95).toColor();

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _amber.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _amber.withValues(alpha: 0.6)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15, color: Colors.white)),
            Text(subtitle, style: const TextStyle(fontSize: 12, color: _muted)),
            const SizedBox(height: 8),
            Row(
              children: [
                for (var v = 0; v <= 10; v++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Tooltip(
                        message: _labels[v] ?? '',
                        child: FilledButton(
                          onPressed: () => onPick(v),
                          style: FilledButton.styleFrom(
                            backgroundColor: colorOf(v),
                            foregroundColor: Colors.black,
                            minimumSize: const Size(0, 44),
                            padding: EdgeInsets.zero,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          child: Text('$v', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      );
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({
    required this.index,
    required this.session,
    required this.open,
    required this.onToggle,
    required this.send,
  });

  final int index;
  final MonitorSession session;
  final bool open;
  final VoidCallback onToggle;
  final SessionCommandSender send;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final activity = s.activityAt(index);
    final log = s.lastLogOf(index);
    final attempts = s.logs.where((l) => l.activityIndex == index).length;
    final current = !s.isIdle && !s.isWait && s.activityIndex == index && !s.isClosing;
    final upcoming = !s.isIdle && s.isWait && s.nextIndex == index && !s.protocolComplete;

    final (IconData icon, Color color, String state) = current
        ? (Icons.play_circle_fill_rounded, phaseLook(s.phase).color, phaseLook(s.phase).label.toLowerCase())
        : log == null
            ? upcoming
                ? (Icons.radio_button_checked_rounded, _accent, 'siguiente')
                : (Icons.radio_button_unchecked_rounded, Colors.white30, 'pendiente')
            : log.isSkipped
                ? (Icons.do_not_disturb_on_rounded, Colors.white38, 'no realizada')
                : log.isPartial
                    ? (Icons.timelapse_rounded, _amber, 'parcial · ${formatClock(log.durationSeconds)}')
                    : (Icons.check_circle_rounded, _green, 'hecha · ${formatClock(log.durationSeconds)}');

    final details = <String>[
      if (log?.rpe != null) 'RPE ${log!.rpe}',
      if (s.rpeBefore[index] != null) 'RPE antes ${s.rpeBefore[index]}',
      if (log?.restingHr != null) 'FC reposo ${log!.restingHr} lpm',
      if (attempts > 1) '$attempts intentos',
      if (log?.incident != null) 'incidencia',
    ];

    final canGo = !s.isIdle && !s.isClosing && (s.isWait || s.phase == 'static_prep') && !current && !upcoming;

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: current || upcoming ? color.withValues(alpha: 0.10) : const Color(0xFF0B1220),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: current || upcoming ? color.withValues(alpha: 0.7) : Colors.white10),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: log == null ? null : onToggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  Icon(icon, color: color, size: 20),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 22,
                    child: Text('$index', style: const TextStyle(color: Colors.white38, fontWeight: FontWeight.w800)),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          activity?.name ?? 'Actividad $index',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white, fontSize: 13),
                        ),
                        Text(
                          [state, ...details].join(' · '),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: color == Colors.white30 ? Colors.white38 : color),
                        ),
                      ],
                    ),
                  ),
                  if (activity?.durationSeconds != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Text(
                        formatClock(activity!.durationSeconds!),
                        style: const TextStyle(fontSize: 11, color: Colors.white38),
                      ),
                    ),
                  if (canGo)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Tooltip(
                        message: s.isWait ? 'Hacer esta la siguiente' : 'Empezar esta actividad ahora',
                        child: IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.subdirectory_arrow_right_rounded, size: 18),
                          color: _accent,
                          onPressed: () async {
                            final ok = await confirmAction(
                              context,
                              title: 'Ir a «${activity?.name ?? 'Actividad $index'}»',
                              message: s.isWait
                                  ? 'Será la siguiente actividad; empieza cuando pulses SIGUIENTE.'
                                  : 'Se deja la fase estática actual y empieza esta actividad.',
                              confirm: 'Ir',
                            );
                            if (ok) await send('goto', {'index': index});
                          },
                        ),
                      ),
                    ),
                  if (log != null)
                    Icon(open ? Icons.expand_less_rounded : Icons.edit_note_rounded, color: Colors.white38, size: 18),
                ],
              ),
            ),
          ),
          if (open && log != null)
            _LogEditor(
              key: ValueKey('editor_${log.logIndex}'),
              log: log,
              activity: activity,
              send: send,
              onDone: onToggle,
            ),
        ],
      ),
    );
  }
}

/// Activities without a protocol: only what was logged.
class _LogOnlyList extends StatelessWidget {
  const _LogOnlyList({required this.session, required this.send});

  final MonitorSession session;
  final SessionCommandSender send;

  @override
  Widget build(BuildContext context) {
    final logs = session.logs;
    if (logs.isEmpty) {
      return const Center(
        child: Text('Las actividades aparecerán aquí al terminarlas.', style: TextStyle(color: _muted)),
      );
    }
    return ListView(
      children: [
        for (final log in logs.reversed)
          ListTile(
            dense: true,
            title: Text('Actividad ${log.activityIndex}'),
            subtitle: Text('${formatClock(log.durationSeconds)}${log.rpe == null ? '' : ' · RPE ${log.rpe}'}'),
          ),
      ],
    );
  }
}

class _LogEditor extends StatefulWidget {
  const _LogEditor({super.key, required this.log, required this.activity, required this.send, required this.onDone});

  final MonitorLog log;
  final BatteryActivity? activity;
  final SessionCommandSender send;
  final VoidCallback onDone;

  @override
  State<_LogEditor> createState() => _LogEditorState();
}

class _LogEditorState extends State<_LogEditor> {
  late String _completion = widget.log.completion;
  late int? _rpe = widget.log.rpe;
  late final TextEditingController _incident = TextEditingController(text: widget.log.incident ?? '');
  late final TextEditingController _restingHr =
      TextEditingController(text: widget.log.restingHr?.toString() ?? '');
  final Map<String, TextEditingController> _fields = {};
  final Map<String, String?> _choices = {};
  String? _error;
  bool _saving = false;

  List<RecordField> get _recordFields => widget.activity?.redcap?.fields ?? const [];

  @override
  void initState() {
    super.initState();
    final values = widget.log.fields;
    for (final f in _recordFields) {
      final value = values[f.field] ?? f.defaultValue ?? '';
      if (f.type == 'choice') {
        _choices[f.field] = value.isEmpty ? null : value;
      } else {
        _fields[f.field] = TextEditingController(text: value);
      }
    }
  }

  @override
  void dispose() {
    _incident.dispose();
    _restingHr.dispose();
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final fields = <String, String>{};
    for (final f in _recordFields) {
      final value = f.type == 'choice' ? (_choices[f.field] ?? '') : _fields[f.field]!.text;
      final problem = f.validate(value);
      if (problem != null) {
        setState(() => _error = '${f.label}: $problem');
        return;
      }
      fields[f.field] = f.normalize(value);
    }
    final hrText = _restingHr.text.trim();
    final hr = hrText.isEmpty ? null : int.tryParse(hrText);
    if (hrText.isNotEmpty && (hr == null || hr < 25 || hr > 230)) {
      setState(() => _error = 'FC de reposo: entre 25 y 230 lpm');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final reply = await widget.send('annotate', {
      'log_index': widget.log.logIndex,
      'completion': _completion,
      'rpe': _rpe,
      'incident': _incident.text,
      'fields': fields,
      if (widget.activity?.restingHr == true || widget.log.restingHr != null) 'resting_hr': hr,
    });
    if (!mounted) return;
    setState(() => _saving = false);
    if (reply['ok'] == false) {
      setState(() => _error = reply['message']?.toString() ?? 'No se pudo guardar');
      return;
    }
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final showHr = widget.activity?.restingHr == true || widget.log.restingHr != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Divider(height: 12),
          Row(
            children: [
              const Text('Resultado', style: TextStyle(color: _muted, fontSize: 12)),
              const SizedBox(width: 10),
              Expanded(
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'complete', label: Text('Completa')),
                    ButtonSegment(value: 'partial', label: Text('Parcial')),
                    ButtonSegment(value: 'skipped', label: Text('No realizada')),
                  ],
                  selected: {_completion},
                  showSelectedIcon: false,
                  onSelectionChanged: (v) => setState(() => _completion = v.first),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Text('RPE', style: TextStyle(color: _muted, fontSize: 12)),
              const SizedBox(width: 10),
              for (var v = 0; v <= 10; v++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1),
                    child: InkWell(
                      onTap: () => setState(() => _rpe = _rpe == v ? null : v),
                      child: Container(
                        height: 30,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: _rpe == v ? _BorgPicker.colorOf(v) : Colors.white10,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '$v',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            color: _rpe == v ? Colors.black : Colors.white70,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          for (final f in _recordFields) ...[
            const SizedBox(height: 10),
            if (f.type == 'choice')
              DropdownButtonFormField<String>(
                // ignore: deprecated_member_use
                value: _choices[f.field],
                isExpanded: true,
                decoration: InputDecoration(labelText: f.label, isDense: true, border: const OutlineInputBorder()),
                items: [
                  for (final e in f.choices.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) => setState(() => _choices[f.field] = v),
              )
            else
              TextField(
                controller: _fields[f.field],
                keyboardType: f.isNumeric ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
                decoration: InputDecoration(
                  labelText: f.label,
                  isDense: true,
                  border: const OutlineInputBorder(),
                  helperText: f.isNumeric && (f.min != null || f.max != null)
                      ? [if (f.min != null) 'mín. ${f.min}', if (f.max != null) 'máx. ${f.max}'].join(' · ')
                      : null,
                ),
              ),
          ],
          if (showHr) ...[
            const SizedBox(height: 10),
            TextField(
              controller: _restingHr,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'FC de reposo (lpm)',
                helperText: 'Calculada con la H10 en los últimos 2 min; se puede corregir',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ],
          const SizedBox(height: 10),
          TextField(
            controller: _incident,
            decoration: const InputDecoration(
              labelText: 'Incidencias (opcional)',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: const TextStyle(color: _red, fontWeight: FontWeight.w600)),
            ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: widget.onDone, child: const Text('Cerrar')),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: const Icon(Icons.check_rounded, size: 18),
                label: const Text('Guardar'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Before the start and after the end
// =============================================================================

/// Shows what is ready. Returns `true` to start with video, `false` to
/// start without it, null to go back.
Future<bool?> showPreflightDialog(
  BuildContext context, {
  required List<PreflightItem> items,
  required bool cameraReady,
}) {
  final problems = items.where((i) => !i.ok).toList();
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: const Color(0xFF1E293B),
      title: Text(problems.isEmpty ? 'Todo listo' : 'Antes de empezar'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final item in items)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      item.manual
                          ? Icons.back_hand_outlined
                          : item.ok
                              ? Icons.check_circle_rounded
                              : Icons.warning_amber_rounded,
                      color: item.manual
                          ? _accent
                          : item.ok
                              ? _green
                              : _amber,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(item.label, style: const TextStyle(fontWeight: FontWeight.w800)),
                          Text(item.detail, style: const TextStyle(color: Colors.white60, fontSize: 12)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            if (problems.isNotEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: Text(
                  'Se puede empezar igualmente; lo que no esté conectado no se registra '
                  'hasta que se conecte.',
                  style: TextStyle(color: Colors.white60, fontSize: 12),
                ),
              ),
          ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Volver')),
        if (!cameraReady)
          FilledButton.tonal(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Empezar sin vídeo'),
          ),
        if (cameraReady) ...[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Sin vídeo'),
          ),
          FilledButton.icon(
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Empezar con vídeo'),
          ),
        ],
      ],
    ),
  );
}

/// What was saved, and REDCap.
Future<void> showSessionSummaryDialog(
  BuildContext context, {
  required MonitorSession session,
  required SessionCommandSender send,
  void Function(String path)? onOpenFolder,
  required VoidCallback onNewSession,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final summary = session.summary ?? const {};
        final dir = summary['directory']?.toString() ?? session.sessionDir;
        final redcapError = summary['redcap_error']?.toString();
        final redcapSkipped = summary['redcap_skipped'] == true;
        final storeError = summary['store_error']?.toString();
        final files = (summary['files'] as List? ?? const []).length;
        final done = (summary['done'] as num?)?.toInt() ?? 0;
        final partial = (summary['partial'] as num?)?.toInt() ?? 0;
        final skipped = (summary['skipped'] as num?)?.toInt() ?? 0;
        final notDone = (summary['not_done'] as num?)?.toInt() ?? 0;
        final syncs = (summary['sync_windows'] as num?)?.toInt() ?? 0;
        final video = summary['video_saved'] == true;
        final total = (summary['total_seconds'] as num?)?.toDouble() ?? 0;

        final after = SensorsAfterSession(session.battery?.sensors ?? const []);
        final unnamed = [
          for (final sensor in after.withoutSerial)
            if (SensorsAfterSession.fileNameFor(sensor, dir) case final name?) name,
        ];
        String names(List<SessionSensor> sensors) => sensors.map((s) => s.displayName).join(', ');

        Widget line(IconData icon, Color color, String text) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, color: color, size: 18),
                  const SizedBox(width: 8),
                  Expanded(child: Text(text, style: const TextStyle(height: 1.3))),
                ],
              ),
            );

        return AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          title: const Text('Sesión guardada'),
          content: SizedBox(
            width: 560,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                line(Icons.timer_outlined, Colors.white70, 'Duración: ${formatClock(total)}'),
                line(
                  Icons.checklist_rounded,
                  notDone + skipped > 0 ? _amber : _green,
                  'Actividades: $done ${done == 1 ? 'completa' : 'completas'}'
                      '${partial > 0 ? ', $partial ${partial == 1 ? 'parcial' : 'parciales'}' : ''}'
                      '${skipped > 0 ? ', $skipped ${skipped == 1 ? 'saltada' : 'saltadas'}' : ''}'
                      '${notDone > 0 ? ', $notDone sin hacer' : ''}',
                ),
                line(Icons.sync_rounded, syncs > 0 ? _green : _amber, '$syncs ventanas de sincronización'),
                line(
                  video ? Icons.videocam_rounded : Icons.videocam_off_rounded,
                  video ? _green : _amber,
                  video ? 'Vídeo guardado en la carpeta' : 'Sin vídeo',
                ),
                line(Icons.description_outlined, Colors.white70, '$files archivos en la carpeta'),
                if (storeError != null) line(Icons.error_rounded, _red, 'Error al escribir: $storeError'),
                const SizedBox(height: 6),
                if (redcapSkipped)
                  line(Icons.cloud_off_rounded, _amber,
                      'REDCap no está configurado: los registros quedan en redcap_records.json')
                else if (redcapError != null)
                  line(Icons.cloud_off_rounded, _red,
                      'REDCap: $redcapError\nLos registros quedan en redcap_records.json.')
                else
                  line(Icons.cloud_done_rounded, _green, 'Enviado a REDCap'),
                if (!after.isEmpty) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'ANTES DE QUE SE VAYA EL PARTICIPANTE',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                      color: Colors.white70,
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (after.download.isNotEmpty)
                    line(Icons.download_rounded, _amber,
                        'Descarga y copia a la carpeta de la sesión: ${names(after.download)}.'),
                  if (after.downloadAndRestart.isNotEmpty)
                    line(Icons.restart_alt_rounded, _amber,
                        'Descarga, copia a la carpeta y vuelve a inicializar para la vida libre: '
                        '${names(after.downloadAndRestart)}.'),
                  if (after.startFreeLiving.isNotEmpty)
                    line(Icons.play_circle_outline_rounded, _amber,
                        'Inicia su grabación de vida libre (lo del laboratorio ya está en la carpeta): '
                        '${names(after.startFreeLiving)}.'),
                  if (unnamed.isNotEmpty)
                    line(Icons.drive_file_rename_outline_rounded, Colors.white70,
                        'Sin número de serie en la configuración: nombra sus archivos ${unnamed.join(', ')} '
                        '(con su extensión) para que SAVES los reconozca.'),
                ],
                if (dir != null) ...[
                  const SizedBox(height: 8),
                  SelectableText(dir, style: const TextStyle(fontSize: 12, color: Colors.white54)),
                ],
              ],
            ),
          ),
          actions: [
            if (dir != null && onOpenFolder != null)
              TextButton.icon(
                onPressed: () => onOpenFolder(dir),
                icon: const Icon(Icons.folder_open_rounded),
                label: const Text('Abrir carpeta'),
              ),
            if (redcapError != null && !redcapSkipped)
              TextButton.icon(
                onPressed: () => send('redcap_retry'),
                icon: const Icon(Icons.cloud_upload_rounded),
                label: const Text('Reintentar REDCap'),
              ),
            FilledButton(
              onPressed: () {
                Navigator.of(context).pop();
                onNewSession();
              },
              child: const Text('Terminar'),
            ),
          ],
        );
      },
    ),
  );
}
