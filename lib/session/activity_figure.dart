import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Animated figure of an activity for the participant's screen: still in
/// the static phases (the start posture), moving in the activity.
class ActivityFigure extends StatefulWidget {
  const ActivityFigure({
    super.key,
    required this.animation,
    required this.moving,
    this.color = Colors.white,
    this.propColor = const Color(0x66FFFFFF),
  });

  /// One of [activityAnimations].
  final String animation;
  final bool moving;
  final Color color;
  final Color propColor;

  @override
  State<ActivityFigure> createState() => _ActivityFigureState();
}

class _ActivityFigureState extends State<ActivityFigure>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    // Seconds as the value; the painter makes each cycle from it.
    _controller = AnimationController.unbounded(vsync: this);
    _sync();
  }

  @override
  void didUpdateWidget(ActivityFigure oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.moving != widget.moving ||
        oldWidget.animation != widget.animation) {
      _sync();
    }
  }

  void _sync() {
    if (widget.moving) {
      _controller.repeat(
        min: 0,
        max: 1000,
        period: const Duration(seconds: 1000),
      );
    } else {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => CustomPaint(
          painter: FigurePainter(
            animation: widget.animation,
            seconds: widget.moving ? _controller.value : 0,
            moving: widget.moving,
            color: widget.color,
            propColor: widget.propColor,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

/// Joint angles of the figure (radians). Leg and arm angles are absolute:
/// 0 points down, positive points forward (the figure faces right). The
/// torso angle is its lean forward from upright.
class StickPose {
  const StickPose({
    this.hip = const Offset(0, -0.44),
    this.torso = 0.03,
    this.head = 0,
    this.thighL = 0.04,
    this.shinL = 0.02,
    this.thighR = -0.04,
    this.shinR = -0.02,
    this.armUL = 0.2,
    this.armLL = 0.34,
    this.armUR = -0.12,
    this.armLR = -0.02,
    this.feetOnGround = true,
  });

  /// Hip position: x forward, y up negative, in figure heights from the
  /// ground point under the figure.
  final Offset hip;
  final double torso;
  final double head;
  final double thighL, shinL, thighR, shinR;
  final double armUL, armLL, armUR, armLR;

  /// Lift or lower the hip so the lower foot touches the ground.
  final bool feetOnGround;

  StickPose copyWith({
    Offset? hip,
    double? torso,
    double? thighL,
    double? shinL,
    double? thighR,
    double? shinR,
    double? armUL,
    double? armLL,
    double? armUR,
    double? armLR,
    bool? feetOnGround,
  }) =>
      StickPose(
        hip: hip ?? this.hip,
        torso: torso ?? this.torso,
        head: head,
        thighL: thighL ?? this.thighL,
        shinL: shinL ?? this.shinL,
        thighR: thighR ?? this.thighR,
        shinR: shinR ?? this.shinR,
        armUL: armUL ?? this.armUL,
        armLL: armLL ?? this.armLL,
        armUR: armUR ?? this.armUR,
        armLR: armLR ?? this.armLR,
        feetOnGround: feetOnGround ?? this.feetOnGround,
      );
}

const double _torsoLen = 0.30;
const double _neckLen = 0.035;
const double _headR = 0.062;
const double _upperArm = 0.15;
const double _foreArm = 0.14;
const double _thigh = 0.22;
const double _shin = 0.22;

Offset _down(double angle, double length) =>
    Offset(math.sin(angle) * length, math.cos(angle) * length);

/// Knee of a two-segment leg from hip to foot (bending forward).
Offset _knee(Offset hip, Offset foot) {
  final d = (foot - hip).distance.clamp(0.001, _thigh + _shin - 0.0005);
  final a = (d * d + _thigh * _thigh - _shin * _shin) / (2 * d);
  final h = math.sqrt(math.max(0, _thigh * _thigh - a * a));
  final dir = (foot - hip) / (foot - hip).distance;
  final mid = hip + dir * a;
  // Perpendicular towards the front (x+).
  var normal = Offset(-dir.dy, dir.dx);
  if (normal.dx < 0) normal = -normal;
  return mid + normal * h;
}

double _angleOf(Offset from, Offset to) {
  final v = to - from;
  return math.atan2(v.dx, v.dy);
}

double _smooth(double x) {
  final t = x.clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

/// Pose of [animation] at [seconds] (0 for the still posture).
StickPose poseFor(String animation, double seconds, {required bool moving}) {
  double phase(double period) => 2 * math.pi * (seconds / period);

  StickPose gait(double period, double legAmp, double armAmp,
      {double kneeFlex = 0.45, double lean = 0.05, double elbow = 0.25}) {
    final p = phase(period);
    final s = math.sin(p);
    final c = math.cos(p);
    final thighL = legAmp * s;
    final thighR = -legAmp * s;
    return StickPose(
      torso: lean,
      thighL: thighL,
      shinL: thighL - kneeFlex * math.max(0, c),
      thighR: thighR,
      shinR: thighR - kneeFlex * math.max(0, -c),
      armUL: -armAmp * s,
      armLL: -armAmp * s + elbow,
      armUR: armAmp * s,
      armLR: armAmp * s + elbow,
    );
  }

  switch (animation) {
    case 'walk':
    case 'uphill':
      if (!moving) return const StickPose();
      return gait(1.1, 0.36, 0.3, lean: animation == 'uphill' ? 0.16 : 0.05);
    case 'walk_bags':
      if (!moving) return const StickPose(armUL: 0.08, armLL: 0.08, armUR: -0.08, armLR: -0.08);
      return gait(1.25, 0.3, 0.08, elbow: 0.02);
    case 'walk_fast':
      if (!moving) return const StickPose();
      return gait(0.8, 0.45, 0.55, kneeFlex: 0.55, lean: 0.09, elbow: 1.0);
    case 'run':
    case 'treadmill':
      if (!moving) {
        return const StickPose(armUL: 0.1, armLL: 1.3, armUR: -0.1, armLR: 1.1);
      }
      final p = phase(0.62);
      final s = math.sin(p);
      final c = math.cos(p);
      return StickPose(
        torso: 0.2,
        thighL: 0.25 + 0.6 * s,
        shinL: 0.25 + 0.6 * s - 0.25 - 1.0 * math.max(0, c),
        thighR: 0.25 - 0.6 * s,
        shinR: 0.25 - 0.6 * s - 0.25 - 1.0 * math.max(0, -c),
        armUL: -0.6 * s,
        armLL: -0.6 * s + 1.45,
        armUR: 0.6 * s,
        armLR: 0.6 * s + 1.45,
      );
    case 'stairs':
      if (!moving) return const StickPose();
      final p = phase(1.3);
      final l = math.max(0.0, math.sin(p));
      final r = math.max(0.0, -math.sin(p));
      return StickPose(
        torso: 0.16,
        thighL: 0.05 + 1.1 * l,
        shinL: 0.05 + 1.1 * l - 1.3 * l,
        thighR: 0.05 + 1.1 * r,
        shinR: 0.05 + 1.1 * r - 1.3 * r,
        armUL: -0.35 * math.sin(p),
        armLL: -0.35 * math.sin(p) + 0.3,
        armUR: 0.35 * math.sin(p),
        armLR: 0.35 * math.sin(p) + 0.3,
      );
    case 'sweep':
      final p = moving ? phase(1.4) : 0.0;
      final swing = 0.25 * math.sin(p);
      return StickPose(
        torso: 0.22,
        thighL: 0.18,
        shinL: 0.12,
        thighR: -0.12,
        shinR: -0.08,
        armUL: 0.65 + swing,
        armLL: 0.95 + swing,
        armUR: 0.45 + swing,
        armLR: 0.95 + swing,
      );
    case 'dishes':
      final p = moving ? phase(0.9) : 0.0;
      return StickPose(
        torso: 0.12,
        armUL: 0.35,
        armLL: 1.45 + 0.18 * math.sin(p),
        armUR: 0.3,
        armLR: 1.4 + 0.18 * math.cos(p),
      );
    case 'sit':
    case 'type':
      final p = moving ? phase(0.5) : 0.0;
      final typing = animation == 'type';
      return StickPose(
        hip: const Offset(-0.05, -0.25),
        torso: typing ? 0.1 : 0.0,
        thighL: math.pi / 2,
        shinL: 0,
        thighR: math.pi / 2 - 0.05,
        shinR: -0.05,
        armUL: typing ? 0.45 : 0.35,
        armLL: typing ? 1.5 + 0.1 * math.max(0, math.sin(p)) : 1.25,
        armUR: typing ? 0.4 : 0.3,
        armLR: typing ? 1.45 + 0.1 * math.max(0, -math.sin(p)) : 1.2,
        feetOnGround: false,
      );
    case 'sit_to_stand':
      // From seated to standing and back, arms crossed on the chest.
      final cycle = moving ? (seconds / 2.0) % 1.0 : 0.0;
      final up = cycle < 0.5 ? _smooth(cycle * 2) : _smooth((1 - cycle) * 2);
      const foot = Offset(0.17, 0);
      final hip = Offset.lerp(const Offset(-0.05, -0.25), const Offset(0.14, -0.435), up)!;
      final knee = _knee(hip, foot);
      final thigh = _angleOf(hip, knee);
      final shin = _angleOf(knee, foot);
      return StickPose(
        hip: hip,
        torso: 0.05 + 0.45 * math.sin(math.pi * up),
        thighL: thigh,
        shinL: shin,
        thighR: thigh - 0.04,
        shinR: shin - 0.02,
        armUL: 0.55,
        armLL: -2.4,
        armUR: 0.5,
        armLR: -2.5,
        feetOnGround: false,
      );
    case 'cycle':
      final p = moving ? phase(1.0) : 0.0;
      const crank = Offset(0.08, -0.17);
      const hip = Offset(-0.06, -0.44);
      final footL = crank + Offset(math.cos(p), math.sin(p)) * 0.085;
      final footR = crank + Offset(math.cos(p + math.pi), math.sin(p + math.pi)) * 0.085;
      final kneeL = _knee(hip, footL);
      final kneeR = _knee(hip, footR);
      return StickPose(
        hip: hip,
        torso: 0.55,
        thighL: _angleOf(hip, kneeL),
        shinL: _angleOf(kneeL, footL),
        thighR: _angleOf(hip, kneeR),
        shinR: _angleOf(kneeR, footR),
        armUL: 1.05,
        armLL: 1.35,
        armUR: 1.0,
        armLR: 1.3,
        feetOnGround: false,
      );
    case 'lie':
    case 'stand':
    default:
      final breath = moving ? 0.01 * math.sin(phase(4.0)) : 0.0;
      return StickPose(torso: 0.02 + breath);
  }
}

class FigurePainter extends CustomPainter {
  FigurePainter({
    required this.animation,
    required this.seconds,
    required this.moving,
    required this.color,
    required this.propColor,
  });

  final String animation;
  final double seconds;
  final bool moving;
  final Color color;
  final Color propColor;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = math.min(size.width / 1.1, size.height / 1.05);
    if (unit <= 0) return;
    final pose = poseFor(animation, seconds, moving: moving);

    canvas.save();
    // Ground point of the figure in the canvas.
    final ground = Offset(size.width / 2, size.height * 0.94);
    canvas.translate(ground.dx, ground.dy);
    canvas.scale(unit);

    final line = Paint()
      ..color = color
      ..strokeWidth = 0.034
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    final far = Paint()
      ..color = color.withValues(alpha: color.a * 0.55)
      ..strokeWidth = 0.032
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final prop = Paint()
      ..color = propColor
      ..strokeWidth = 0.02
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final propFill = Paint()
      ..color = propColor.withValues(alpha: propColor.a * 0.5)
      ..style = PaintingStyle.fill;

    if (animation == 'lie') {
      _paintLying(canvas, line, far, prop, propFill);
      canvas.restore();
      return;
    }

    _paintPropsBehind(canvas, prop, propFill);

    var hip = pose.hip;
    if (pose.feetOnGround) {
      double reach(double thigh, double shin) =>
          _thigh * math.cos(thigh) + _shin * math.cos(shin);
      final lowest = math.max(reach(pose.thighL, pose.shinL), reach(pose.thighR, pose.shinR));
      final lift = animation == 'run' || animation == 'treadmill'
          ? 0.025 * math.sin(2 * math.pi * seconds / 0.62 * 2).abs()
          : 0.0;
      hip = Offset(hip.dx, -lowest - lift);
      if (animation == 'stairs') hip = Offset(hip.dx, hip.dy - 0.0);
    }

    final neck = hip + Offset(math.sin(pose.torso), -math.cos(pose.torso)) * _torsoLen;
    final head = neck + Offset(math.sin(pose.torso + pose.head), -math.cos(pose.torso + pose.head)) * (_neckLen + _headR);
    final shoulder = Offset.lerp(neck, hip, 0.08)!;

    // Far limbs first (dimmer), then the body, then the near limbs.
    final kneeR = hip + _down(pose.thighR, _thigh);
    final footR = kneeR + _down(pose.shinR, _shin);
    final elbowR = shoulder + _down(pose.armUR, _upperArm);
    final handR = elbowR + _down(pose.armLR, _foreArm);
    canvas.drawPath(_poly([hip, kneeR, footR, footR + const Offset(0.045, 0)]), far);
    canvas.drawPath(_poly([shoulder, elbowR, handR]), far);

    canvas.drawLine(hip, neck, line);
    canvas.drawCircle(head, _headR, line);

    final kneeL = hip + _down(pose.thighL, _thigh);
    final footL = kneeL + _down(pose.shinL, _shin);
    final elbowL = shoulder + _down(pose.armUL, _upperArm);
    final handL = elbowL + _down(pose.armLL, _foreArm);
    canvas.drawPath(_poly([hip, kneeL, footL, footL + const Offset(0.045, 0)]), line);
    canvas.drawPath(_poly([shoulder, elbowL, handL]), line);

    _paintPropsFront(canvas, prop, propFill, handL: handL, handR: handR, hip: hip);
    canvas.restore();
  }

  Path _poly(List<Offset> points) {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    return path;
  }

  void _paintLying(Canvas canvas, Paint line, Paint far, Paint prop, Paint fill) {
    // Mat.
    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(-0.5, -0.035, 1.0, 0.035), const Radius.circular(0.012)),
      fill,
    );
    final breath = moving ? 0.006 * math.sin(2 * math.pi * seconds / 4.0) : 0.0;
    const y = -0.07;
    const hip = Offset(0.04, y);
    final neck = Offset(-0.26, y - breath);
    final head = neck + const Offset(-(_neckLen + _headR), -0.01);
    final knee = hip + const Offset(_thigh, -0.005);
    final foot = knee + const Offset(_shin, 0);
    canvas.drawPath(_poly([hip, knee - const Offset(0, 0.004), foot, foot + const Offset(0, -0.045)]), line);
    canvas.drawLine(hip, neck, line);
    canvas.drawCircle(head, _headR, line);
    final shoulder = Offset.lerp(neck, hip, 0.08)!;
    canvas.drawPath(_poly([shoulder, shoulder + const Offset(_upperArm, 0.012), shoulder + const Offset(_upperArm + _foreArm, 0.016)]), line);
  }

  void _paintPropsBehind(Canvas canvas, Paint prop, Paint fill) {
    switch (animation) {
      case 'stairs':
        final shift = moving ? (seconds / 2.6) % 1.0 * 0.12 : 0.0;
        final path = Path()..moveTo(-0.55, 0);
        var x = -0.55 - shift * 1.6;
        var y = 0.0 + shift;
        path.moveTo(x, y);
        for (var i = 0; i < 6; i++) {
          path.lineTo(x + 0.19, y);
          x += 0.19;
          path.lineTo(x, y - 0.12);
          y -= 0.12;
        }
        canvas.save();
        canvas.clipRect(const Rect.fromLTRB(-0.55, -0.8, 0.55, 0.02));
        canvas.drawPath(path, prop);
        canvas.restore();
      case 'uphill':
        canvas.drawLine(const Offset(-0.55, 0.06), const Offset(0.55, -0.06), prop);
      case 'treadmill':
        canvas.drawRRect(
          RRect.fromRectAndRadius(const Rect.fromLTWH(-0.42, 0.0, 0.84, 0.045), const Radius.circular(0.02)),
          prop,
        );
        canvas.drawLine(const Offset(0.36, 0.0), const Offset(0.42, -0.5), prop);
        canvas.drawLine(const Offset(0.42, -0.5), const Offset(0.3, -0.52), prop);
      case 'sit':
      case 'type':
      case 'sit_to_stand':
        // Chair seen from the side.
        canvas.drawLine(const Offset(-0.16, -0.25), const Offset(0.06, -0.25), prop);
        canvas.drawLine(const Offset(-0.15, -0.25), const Offset(-0.15, 0), prop);
        canvas.drawLine(const Offset(0.05, -0.25), const Offset(0.05, 0), prop);
        canvas.drawLine(const Offset(-0.16, -0.25), const Offset(-0.2, -0.6), prop);
        if (animation == 'type') {
          // Desk and keyboard.
          canvas.drawLine(const Offset(0.2, -0.43), const Offset(0.55, -0.43), prop);
          canvas.drawLine(const Offset(0.52, -0.43), const Offset(0.52, 0), prop);
          canvas.drawRect(const Rect.fromLTWH(0.22, -0.455, 0.12, 0.02), fill);
          canvas.drawLine(const Offset(0.44, -0.43), const Offset(0.47, -0.62), prop);
        }
      case 'cycle':
        // Exercise bike: frame, saddle, handlebar and crank.
        canvas.drawLine(const Offset(-0.1, -0.455), const Offset(-0.02, -0.455), prop);
        canvas.drawLine(const Offset(-0.06, -0.455), const Offset(0.08, -0.17), prop);
        canvas.drawLine(const Offset(0.08, -0.17), const Offset(0.3, -0.5), prop);
        canvas.drawLine(const Offset(0.26, -0.55), const Offset(0.36, -0.53), prop);
        canvas.drawCircle(const Offset(0.08, -0.17), 0.085, prop);
        canvas.drawLine(const Offset(-0.2, 0), const Offset(0.4, 0), prop);
        canvas.drawLine(const Offset(0.08, -0.17), const Offset(-0.12, 0), prop);
        canvas.drawLine(const Offset(0.08, -0.17), const Offset(0.3, 0), prop);
      case 'dishes':
        canvas.drawLine(const Offset(0.2, -0.47), const Offset(0.55, -0.47), prop);
        canvas.drawLine(const Offset(0.52, -0.47), const Offset(0.52, 0), prop);
        canvas.drawArc(const Rect.fromLTWH(0.24, -0.55, 0.22, 0.16), 0, math.pi, false, prop);
      default:
        break;
    }
    if (animation != 'stairs' && animation != 'uphill' && animation != 'treadmill') {
      canvas.drawLine(const Offset(-0.55, 0), const Offset(0.55, 0), prop);
    }
  }

  void _paintPropsFront(
    Canvas canvas,
    Paint prop,
    Paint fill, {
    required Offset handL,
    required Offset handR,
    required Offset hip,
  }) {
    switch (animation) {
      case 'walk_bags':
        for (final hand in [handL, handR]) {
          final rect = Rect.fromLTWH(hand.dx - 0.065, hand.dy + 0.03, 0.13, 0.15);
          canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(0.015)), fill);
          canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(0.015)), prop);
          canvas.drawLine(hand, Offset(rect.left + 0.03, rect.top), prop);
          canvas.drawLine(hand, Offset(rect.right - 0.03, rect.top), prop);
        }
      case 'sweep':
        final top = Offset.lerp(handL, handR, 0.5)! + const Offset(-0.05, -0.05);
        final dir = (handL - top);
        final unit = dir / dir.distance;
        final end = Offset(handL.dx + unit.dx * 0.5, 0);
        canvas.drawLine(top, end, prop..strokeWidth = 0.016);
        canvas.drawLine(end + const Offset(-0.07, 0), end + const Offset(0.07, 0), prop..strokeWidth = 0.04);
        prop.strokeWidth = 0.02;
      default:
        break;
    }
  }

  @override
  bool shouldRepaint(FigurePainter old) =>
      old.seconds != seconds ||
      old.animation != animation ||
      old.moving != moving ||
      old.color != color;
}
