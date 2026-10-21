import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/lab_redcap_service.dart';
import 'activity_figure.dart';
import 'protocol_engine.dart';
import 'session_controller.dart';

/// Colours and words of each phase on the participant's screen.
class PhaseStyle {
  final String title;
  final Color accent;
  final Color banner;
  final Color background;
  final IconData icon;

  const PhaseStyle(this.title, this.accent, this.banner, this.background, this.icon);

  static const prep = PhaseStyle(
    'QUIETO',
    Color(0xFFFBBF24),
    Color(0xFF92400E),
    Color(0xFF2A1A05),
    Icons.front_hand_rounded,
  );
  static const main = PhaseStyle(
    '¡ADELANTE!',
    Color(0xFF34D399),
    Color(0xFF065F46),
    Color(0xFF022C22),
    Icons.directions_run_rounded,
  );
  static const post = PhaseStyle(
    'PARA Y QUIETO',
    Color(0xFFF87171),
    Color(0xFF991B1B),
    Color(0xFF3B0A0A),
    Icons.front_hand_rounded,
  );
  static const wait = PhaseStyle(
    'DESCANSO',
    Color(0xFF7DD3FC),
    Color(0xFF1E3A5F),
    Color(0xFF0B1424),
    Icons.self_improvement_rounded,
  );
  static const paused = PhaseStyle(
    'PAUSA',
    Color(0xFFCBD5E1),
    Color(0xFF334155),
    Color(0xFF0F172A),
    Icons.pause_circle_filled_rounded,
  );

  /// Main phase of an activity that is itself a still posture: the running
  /// figure and "¡ADELANTE!" would contradict "no te muevas".
  static const mainStill = PhaseStyle(
    'MANTENTE ASÍ',
    Color(0xFF34D399),
    Color(0xFF065F46),
    Color(0xFF022C22),
    Icons.accessibility_new_rounded,
  );

  static bool isStill(String animation) => const {'lie', 'sit', 'stand'}.contains(animation);

  static PhaseStyle of(SessionPhase phase, [String animation = '']) => switch (phase) {
        SessionPhase.prep => prep,
        SessionPhase.main => isStill(animation) ? mainStill : main,
        SessionPhase.post => post,
        SessionPhase.wait => wait,
      };
}

/// Still posture asked in the static phases of an activity.
String stillPosture(String animation) => switch (animation) {
      'lie' => 'Tumbado boca arriba, sin moverte',
      'sit' || 'type' || 'cycle' || 'sit_to_stand' => 'Sentado, sin moverte',
      _ => 'De pie, sin moverte',
    };

/// Borg CR-10 scale in Spanish, as shown to the participant.
const Map<int, String> borgLabels = {
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

Color borgColor(int value) {
  const stops = [
    Color(0xFF38BDF8),
    Color(0xFF34D399),
    Color(0xFFFACC15),
    Color(0xFFFB923C),
    Color(0xFFEF4444),
    Color(0xFFB91C1C),
  ];
  final t = value / 10 * (stops.length - 1);
  final i = t.floor().clamp(0, stops.length - 2);
  return Color.lerp(stops[i], stops[i + 1], t - i)!;
}

/// Screen the participant sees during the session: what to do now, how
/// long is left, the figure of the activity, the sync cues and the effort
/// scale between activities.
class ParticipantView extends StatelessWidget {
  const ParticipantView({super.key, required this.controller, this.onShowMonitor, this.onNewSession});

  final SessionController controller;

  /// Shows the Research Monitor again (a small button for the evaluator).
  final VoidCallback? onShowMonitor;

  /// Back to the setup once the session is saved or cancelled.
  final VoidCallback? onNewSession;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final engine = controller.engine;
    final closing = controller.closing;
    final Widget body;
    PhaseStyle style;

    if (closing != null || engine.status == SessionStatus.finished) {
      style = PhaseStyle.wait;
      body = _EndScreen(controller: controller, onNewSession: onNewSession);
    } else if (!engine.hasStarted) {
      style = PhaseStyle.wait;
      body = _IdleScreen(controller: controller);
    } else {
      style = engine.isPaused ? PhaseStyle.paused : PhaseStyle.of(engine.phase, engine.plan.animation);
      body = _ActiveScreen(controller: controller, style: style);
    }

    final cue = engine.cue;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [style.background, const Color(0xFF05070C)],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          SafeArea(child: body),
          if (cue != null && engine.isRunning)
            _SyncCueOverlay(
              kind: cue.kind,
              count: cue.went ? 0 : ProtocolEngine.cueLeadSeconds - cue.beeps + 1,
            ),
          if (onShowMonitor != null)
            Positioned(
              right: 6,
              bottom: 6,
              child: Opacity(
                opacity: 0.35,
                child: IconButton(
                  tooltip: 'Mostrar el Research Monitor (F2)',
                  onPressed: onShowMonitor,
                  icon: const Icon(Icons.monitor_heart_rounded, color: Colors.white),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// =============================================================================
// Session running
// =============================================================================

class _ActiveScreen extends StatelessWidget {
  const _ActiveScreen({required this.controller, required this.style});

  final SessionController controller;
  final PhaseStyle style;

  @override
  Widget build(BuildContext context) {
    final engine = controller.engine;
    final plan = engine.plan;
    final phase = engine.phase;
    final paused = engine.isPaused;

    final String headline;
    final String? subline;
    switch (phase) {
      case SessionPhase.prep:
        headline = paused ? 'PAUSA' : style.title;
        subline = stillPosture(plan.animation);
      case SessionPhase.main:
        headline = paused ? 'PAUSA' : style.title;
        subline = PhaseStyle.isStill(plan.animation) ? stillPosture(plan.animation) : null;
      case SessionPhase.post:
        headline = paused ? 'PAUSA' : style.title;
        subline = stillPosture(plan.animation);
      case SessionPhase.wait:
        headline = paused
            ? 'PAUSA'
            : engine.protocolComplete
                ? '¡PROTOCOLO COMPLETADO!'
                : 'DESCANSO';
        subline = engine.protocolComplete ? 'Muy bien. Espera al evaluador.' : null;
    }

    final count = controller.activityCount;
    final showPlan = phase != SessionPhase.wait;
    final shownPlan = showPlan ? plan : _waitPlan(engine);

    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 18, 28, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ProgressHeader(controller: controller, accent: style.accent),
          const SizedBox(height: 14),
          _Banner(
            style: style,
            headline: headline,
            title: showPlan
                ? _activityTitle(plan, count, engine.attempt)
                : engine.protocolComplete
                    ? 'Todas las actividades hechas'
                    : 'Actividad completada',
            subline: subline,
          ),
          const SizedBox(height: 18),
          Expanded(
            child: phase == SessionPhase.wait
                ? _WaitBody(controller: controller, style: style, next: shownPlan)
                : _PhaseBody(controller: controller, style: style),
          ),
          if (phase != SessionPhase.wait) ...[
            const SizedBox(height: 12),
            _NextUp(controller: controller),
          ],
        ],
      ),
    );
  }

  static ActivityPlan? _waitPlan(ProtocolEngine engine) {
    final next = engine.upcomingIndex;
    return next == null ? null : engine.planAt(next);
  }
}

String _activityTitle(ActivityPlan plan, int count, int attempt) {
  final again = attempt > 1 ? ' (otra vez)' : '';
  return '${plan.label}$again';
}

class _ProgressHeader extends StatelessWidget {
  const _ProgressHeader({required this.controller, required this.accent});

  final SessionController controller;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final engine = controller.engine;
    final count = controller.activityCount;
    final current = engine.phase == SessionPhase.wait
        ? engine.upcomingIndex
        : engine.activityIndex;
    final states = <int, String>{};
    for (final log in engine.logs) {
      final previous = states[log.activityIndex];
      if (previous == ActivityCompletion.complete) continue;
      states[log.activityIndex] = log.completion;
    }
    return Row(
      children: [
        if (count > 0)
          Expanded(
            child: Row(
              children: [
                for (var i = 1; i <= count; i++)
                  Expanded(
                    child: Container(
                      height: 10,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(5),
                        color: switch (states[i]) {
                          ActivityCompletion.complete => accent,
                          ActivityCompletion.partial => accent.withValues(alpha: 0.55),
                          ActivityCompletion.skipped => Colors.white24,
                          _ => i == current ? Colors.white70 : Colors.white12,
                        },
                        border: i == current
                            ? Border.all(color: Colors.white, width: 1.5)
                            : null,
                      ),
                    ),
                  ),
              ],
            ),
          )
        else
          const Spacer(),
        const SizedBox(width: 18),
        Text(
          count > 0 && current != null
              ? 'Actividad $current de $count'
              : 'Actividad ${current ?? engine.activityIndex}',
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 20,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.style,
    required this.headline,
    required this.title,
    this.subline,
  });

  final PhaseStyle style;
  final String headline;
  final String title;
  final String? subline;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween(begin: 0.96, end: 1.0).animate(animation),
          child: child,
        ),
      ),
      child: Container(
        key: ValueKey('$headline|$title'),
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
        decoration: BoxDecoration(
          color: style.banner,
          borderRadius: BorderRadius.circular(26),
          border: Border.all(color: style.accent, width: 2),
          boxShadow: [BoxShadow(color: style.accent.withValues(alpha: 0.25), blurRadius: 24)],
        ),
        child: Row(
          children: [
            Icon(style.icon, color: style.accent, size: 64),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      headline,
                      style: TextStyle(
                        color: style.accent,
                        fontSize: 54,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2,
                        height: 1.05,
                      ),
                    ),
                  ),
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                      height: 1.15,
                    ),
                  ),
                  if (subline != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        subline!,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Figure, countdown and instructions of the activity on now.
class _PhaseBody extends StatelessWidget {
  const _PhaseBody({required this.controller, required this.style});

  final SessionController controller;
  final PhaseStyle style;

  @override
  Widget build(BuildContext context) {
    final engine = controller.engine;
    final plan = engine.plan;
    final phase = engine.phase;
    final moving = phase == SessionPhase.main && engine.isRunning;
    final instructions = plan.instructions;
    final text = switch (phase) {
      SessionPhase.prep => instructions == null
          ? 'Cuando suene la señal, empieza.'
          : 'Cuando suene la señal: $instructions',
      SessionPhase.main => instructions ?? 'Haz la actividad a ritmo constante.',
      _ => 'Quédate quieto hasta que acabe la cuenta.',
    };
    final face = engine.calibrationFace;

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth > constraints.maxHeight * 1.15;
        final figure = ActivityFigure(
          animation: plan.animation,
          moving: moving,
          color: moving ? Colors.white : style.accent,
          propColor: Colors.white.withValues(alpha: 0.35),
        );
        final ring = _CountdownRing(
          fraction: engine.phaseFractionLeft,
          seconds: engine.remainingSeconds,
          accent: style.accent,
          label: face != null ? 'CARA $face DE ${plan.faces ?? 6}' : 'QUEDAN',
        );
        final instructionText = Text(
          text,
          textAlign: wide ? TextAlign.left : TextAlign.center,
          style: TextStyle(
            color: Colors.white,
            fontSize: wide ? 30 : 26,
            fontWeight: FontWeight.w600,
            height: 1.25,
          ),
        );

        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 5, child: _FigureCard(child: figure)),
              const SizedBox(width: 24),
              Expanded(
                flex: 4,
                child: Column(
                  children: [
                    Expanded(flex: 3, child: ring),
                    const SizedBox(height: 14),
                    Expanded(
                      flex: 2,
                      child: Align(alignment: Alignment.topLeft, child: instructionText),
                    ),
                  ],
                ),
              ),
            ],
          );
        }
        return Column(
          children: [
            Expanded(
              flex: 4,
              child: Row(
                children: [
                  Expanded(child: _FigureCard(child: figure)),
                  const SizedBox(width: 16),
                  Expanded(child: ring),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Expanded(flex: 2, child: Center(child: instructionText)),
          ],
        );
      },
    );
  }
}

class _FigureCard extends StatelessWidget {
  const _FigureCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: Colors.white10),
      ),
      padding: const EdgeInsets.all(18),
      child: child,
    );
  }
}

/// Seconds left, big, with a ring that empties smoothly.
class _CountdownRing extends StatelessWidget {
  const _CountdownRing({
    required this.fraction,
    required this.seconds,
    required this.accent,
    required this.label,
  });

  final double fraction;
  final int seconds;
  final Color accent;
  final String label;

  @override
  Widget build(BuildContext context) {
    final minutes = seconds ~/ 60;
    final rest = seconds % 60;
    final text = minutes > 0
        ? '$minutes:${rest.toString().padLeft(2, '0')}'
        : '$rest';
    final urgent = seconds <= 3;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = math.min(constraints.maxWidth, constraints.maxHeight);
        return Center(
          child: SizedBox(
            width: size,
            height: size,
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: fraction),
              duration: const Duration(milliseconds: 950),
              builder: (context, value, _) => CustomPaint(
                painter: _RingPainter(value, accent),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          color: Colors.white60,
                          fontSize: size * 0.065,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 2,
                        ),
                      ),
                      Text(
                        text,
                        style: TextStyle(
                          color: urgent ? accent : Colors.white,
                          fontSize: size * (minutes > 0 ? 0.25 : 0.34),
                          fontWeight: FontWeight.w900,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          height: 1.0,
                        ),
                      ),
                      if (minutes == 0)
                        Text(
                          'segundos',
                          style: TextStyle(
                            color: Colors.white54,
                            fontSize: size * 0.06,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.fraction, this.color);

  final double fraction;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.shortestSide * 0.07;
    final rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: size.shortestSide / 2 - stroke / 2 - 2,
    );
    canvas.drawArc(
      rect,
      0,
      math.pi * 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = Colors.white.withValues(alpha: 0.08),
    );
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 2 * fraction.clamp(0.0, 1.0),
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = stroke
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.fraction != fraction || old.color != color;
}

class _NextUp extends StatelessWidget {
  const _NextUp({required this.controller});

  final SessionController controller;

  @override
  Widget build(BuildContext context) {
    final engine = controller.engine;
    final next = engine.activityIndex + 1;
    final last = engine.lastIndex;
    if (last != null && next > last) {
      return const _NextLine(text: 'Es la última actividad', animation: null);
    }
    final plan = engine.planAt(next);
    return _NextLine(text: 'Después: ${plan.label}', animation: plan.animation);
  }
}

class _NextLine extends StatelessWidget {
  const _NextLine({required this.text, required this.animation});

  final String text;
  final String? animation;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          if (animation != null)
            SizedBox(
              width: 54,
              height: 46,
              child: ActivityFigure(
                animation: animation!,
                moving: false,
                color: Colors.white60,
                propColor: Colors.white24,
              ),
            ),
          if (animation != null) const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white60, fontSize: 22, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Wait between activities: effort and what comes next
// =============================================================================

class _WaitBody extends StatelessWidget {
  const _WaitBody({required this.controller, required this.style, required this.next});

  final SessionController controller;
  final PhaseStyle style;
  final ActivityPlan? next;

  @override
  Widget build(BuildContext context) {
    final engine = controller.engine;
    final pending = controller.pendingRpeLog;
    final before = controller.rpeBeforeFor;
    final rest = engine.phaseElapsed.inSeconds;

    if (pending != null && !engine.isPaused) {
      final log = engine.logs[pending];
      return _BorgScale(
        question: '¿Cuánto esfuerzo te ha costado?',
        detail: log.activityName ?? 'Actividad ${log.activityIndex}',
      );
    }
    if (before != null && !engine.isPaused) {
      return _BorgScale(
        question: 'Antes de empezar: ¿cuánto esfuerzo sientes ahora?',
        detail: engine.planAt(before).label,
      );
    }

    final plan = next;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 5,
          child: plan == null
              ? _FigureCard(
                  child: Center(
                    child: Icon(Icons.emoji_events_rounded, color: style.accent, size: 160),
                  ),
                )
              : _FigureCard(
                  child: Column(
                    children: [
                      const Text(
                        'SIGUIENTE ACTIVIDAD',
                        style: TextStyle(
                          color: Colors.white54,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 2,
                        ),
                      ),
                      Expanded(
                        child: ActivityFigure(
                          animation: plan.animation,
                          moving: true,
                          color: Colors.white70,
                          propColor: Colors.white24,
                        ),
                      ),
                    ],
                  ),
                ),
        ),
        const SizedBox(width: 24),
        Expanded(
          flex: 4,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (plan != null) ...[
                Text(
                  plan.label,
                  style: const TextStyle(color: Colors.white, fontSize: 34, fontWeight: FontWeight.w900),
                ),
                if (plan.instructions != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      plan.instructions!,
                      style: const TextStyle(color: Colors.white70, fontSize: 24, height: 1.3),
                    ),
                  ),
                const SizedBox(height: 22),
                const Text(
                  'Espera a que el evaluador la inicie.',
                  style: TextStyle(color: Colors.white54, fontSize: 22),
                ),
              ],
              const SizedBox(height: 22),
              Text(
                'Descanso: ${_clock(rest)}',
                style: TextStyle(
                  color: style.accent,
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

String _clock(int seconds) =>
    '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';

/// Borg CR-10 scale: the participant says a number and the evaluator taps
/// it in the Research Monitor.
class _BorgScale extends StatelessWidget {
  const _BorgScale({required this.question, required this.detail});

  final String question;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          question,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 36, fontWeight: FontWeight.w900),
        ),
        Text(
          '$detail · dilo en voz alta',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white60, fontSize: 22),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final rowHeight = (constraints.maxHeight / 11).clamp(20.0, 64.0);
              return Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var v = 10; v >= 0; v--)
                    SizedBox(
                      height: rowHeight,
                      child: Row(
                        children: [
                          SizedBox(
                            width: rowHeight * 1.6,
                            child: Text(
                              '$v',
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: rowHeight * 0.62,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: FractionallySizedBox(
                              alignment: Alignment.centerLeft,
                              widthFactor: 0.25 + 0.075 * v,
                              child: Container(
                                margin: const EdgeInsets.symmetric(vertical: 2),
                                decoration: BoxDecoration(
                                  color: borgColor(v),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  borgLabels[v] ?? '',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.black,
                                    fontSize: rowHeight * 0.42,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// Sync cue
// =============================================================================

/// 3-2-1 and the go of a clap or a jump, over the whole screen.
class _SyncCueOverlay extends StatelessWidget {
  const _SyncCueOverlay({required this.kind, required this.count});

  final String kind;

  /// 3, 2, 1, or 0 for the go.
  final int count;

  @override
  Widget build(BuildContext context) {
    final jump = kind == 'jump';
    final go = count <= 0;
    final color = go ? const Color(0xFF22D3EE) : const Color(0xFF0E7490);
    final title = go ? (jump ? '¡SALTA!' : '¡PALMADA!') : '$count';
    final detail = jump
        ? 'Un salto con los pies juntos'
        : 'Choca las muñecas y golpea el muslo con el puño';
    return ColoredBox(
      color: color.withValues(alpha: go ? 0.96 : 0.9),
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = math.min(constraints.maxWidth, constraints.maxHeight);
            return Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  go ? 'AHORA' : (jump ? 'PREPÁRATE PARA SALTAR' : 'PREPÁRATE PARA LA PALMADA'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: go ? Colors.black : Colors.white,
                    fontSize: size * 0.06,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 2,
                  ),
                ),
                Icon(
                  jump ? Icons.keyboard_double_arrow_up_rounded : Icons.back_hand_rounded,
                  size: size * 0.16,
                  color: go ? Colors.black : Colors.white70,
                ),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    title,
                    style: TextStyle(
                      color: go ? Colors.black : Colors.white,
                      fontSize: size * (go ? 0.24 : 0.42),
                      fontWeight: FontWeight.w900,
                      height: 1.0,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  go ? detail : 'Una sola vez, y luego quieto',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: go ? Colors.black87 : Colors.white70,
                    fontSize: size * 0.045,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

// =============================================================================
// Before and after
// =============================================================================

class _IdleScreen extends StatelessWidget {
  const _IdleScreen({required this.controller});

  final SessionController controller;

  @override
  Widget build(BuildContext context) {
    final engine = controller.engine;
    final plan = engine.plan;
    final title = controller.battery?.displayName;
    return Padding(
      padding: const EdgeInsets.all(36),
      child: Row(
        children: [
          Expanded(
            flex: 5,
            child: _FigureCard(
              child: ActivityFigure(
                animation: plan.animation,
                moving: false,
                color: PhaseStyle.wait.accent,
                propColor: Colors.white24,
              ),
            ),
          ),
          const SizedBox(width: 32),
          Expanded(
            flex: 5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  controller.resumed ? 'SESIÓN RECUPERADA' : 'PREPARADOS',
                  style: TextStyle(
                    color: PhaseStyle.wait.accent,
                    fontSize: 48,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 2,
                  ),
                ),
                if (title != null)
                  Text(title, style: const TextStyle(color: Colors.white70, fontSize: 24)),
                const SizedBox(height: 24),
                Text(
                  'Primera actividad: ${plan.label}',
                  style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w800),
                ),
                if (plan.instructions != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      plan.instructions!,
                      style: const TextStyle(color: Colors.white70, fontSize: 24, height: 1.3),
                    ),
                  ),
                const SizedBox(height: 28),
                const _HowItWorks(),
                const SizedBox(height: 24),
                const Text(
                  'El evaluador iniciará la sesión desde el Research Monitor.',
                  style: TextStyle(color: Colors.white38, fontSize: 18),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The four colours of the screen, explained before the start.
class _HowItWorks extends StatelessWidget {
  const _HowItWorks();

  @override
  Widget build(BuildContext context) {
    Widget item(PhaseStyle style, String title, String text) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(color: style.accent, shape: BoxShape.circle),
              ),
              const SizedBox(width: 12),
              Text(title, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(text, style: const TextStyle(color: Colors.white60, fontSize: 20)),
              ),
            ],
          ),
        );
    return Column(
      children: [
        item(PhaseStyle.prep, 'Amarillo', 'quieto antes de empezar'),
        item(PhaseStyle.main, 'Verde', 'haz la actividad'),
        item(PhaseStyle.post, 'Rojo', 'para y quédate quieto'),
        item(const PhaseStyle('', Color(0xFF22D3EE), Colors.black, Colors.black, Icons.circle),
            'Azul', 'palmada o salto al llegar a cero'),
      ],
    );
  }
}

class _EndScreen extends StatelessWidget {
  const _EndScreen({required this.controller, this.onNewSession});

  final SessionController controller;
  final VoidCallback? onNewSession;

  @override
  Widget build(BuildContext context) {
    final closing = controller.closing;
    final cancelled = closing == 'cancelled';
    final saving = closing == 'finishing';
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            cancelled ? Icons.cancel_rounded : Icons.emoji_events_rounded,
            size: 160,
            color: cancelled ? Colors.white38 : const Color(0xFFFBBF24),
          ),
          const SizedBox(height: 18),
          Text(
            cancelled ? 'Sesión cancelada' : '¡Sesión terminada!',
            style: const TextStyle(color: Colors.white, fontSize: 56, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 8),
          Text(
            cancelled ? 'Los datos grabados se conservan.' : 'Muchas gracias por tu participación.',
            style: const TextStyle(color: Colors.white70, fontSize: 28),
          ),
          if (saving) ...[
            const SizedBox(height: 28),
            const SizedBox(width: 280, child: LinearProgressIndicator()),
            const SizedBox(height: 10),
            const Text('Guardando los datos...', style: TextStyle(color: Colors.white54, fontSize: 20)),
          ] else if (onNewSession != null) ...[
            const SizedBox(height: 40),
            OutlinedButton.icon(
              onPressed: onNewSession,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white54,
                side: const BorderSide(color: Colors.white24),
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              ),
              icon: const Icon(Icons.home_rounded),
              label: const Text('Volver al inicio'),
            ),
          ],
        ],
      ),
    );
  }
}
