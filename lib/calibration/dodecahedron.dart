import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Small 3D vector for the dodecahedron drawing.
class V3 {
  const V3(this.x, this.y, this.z);
  final double x, y, z;

  V3 operator +(V3 o) => V3(x + o.x, y + o.y, z + o.z);
  V3 operator -(V3 o) => V3(x - o.x, y - o.y, z - o.z);
  V3 operator *(double k) => V3(x * k, y * k, z * k);
  double dot(V3 o) => x * o.x + y * o.y + z * o.z;
  V3 cross(V3 o) => V3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x);
  double get length => math.sqrt(dot(this));
  V3 get unit => this * (1 / length);
}

/// Unit quaternion for the rotations of the drawing.
class Quat {
  const Quat(this.w, this.x, this.y, this.z);
  final double w, x, y, z;

  static const identity = Quat(1, 0, 0, 0);

  factory Quat.axisAngle(V3 axis, double angle) {
    final a = axis.unit;
    final s = math.sin(angle / 2);
    return Quat(math.cos(angle / 2), a.x * s, a.y * s, a.z * s);
  }

  /// Shortest rotation that takes direction [from] to direction [to].
  factory Quat.between(V3 from, V3 to) {
    final f = from.unit, t = to.unit;
    final d = f.dot(t).clamp(-1.0, 1.0);
    if (d > 0.999999) return identity;
    if (d < -0.999999) {
      final axis = f.cross(const V3(1, 0, 0)).length > 1e-6
          ? f.cross(const V3(1, 0, 0))
          : f.cross(const V3(0, 1, 0));
      return Quat.axisAngle(axis, math.pi);
    }
    return Quat.axisAngle(f.cross(t), math.acos(d));
  }

  Quat operator *(Quat q) => Quat(
        w * q.w - x * q.x - y * q.y - z * q.z,
        w * q.x + x * q.w + y * q.z - z * q.y,
        w * q.y - x * q.z + y * q.w + z * q.x,
        w * q.z + x * q.y - y * q.x + z * q.w,
      );

  V3 rotate(V3 v) {
    final q = this * Quat(0, v.x, v.y, v.z) * Quat(w, -x, -y, -z);
    return V3(q.x, q.y, q.z);
  }

  /// Spherical interpolation from this to [b] at [t] (0-1).
  Quat slerp(Quat b, double t) {
    var d = w * b.w + x * b.x + y * b.y + z * b.z;
    var bb = b;
    if (d < 0) {
      d = -d;
      bb = Quat(-b.w, -b.x, -b.y, -b.z);
    }
    if (d > 0.9995) {
      final r = Quat(w + (bb.w - w) * t, x + (bb.x - x) * t, y + (bb.y - y) * t, z + (bb.z - z) * t);
      final n = math.sqrt(r.w * r.w + r.x * r.x + r.y * r.y + r.z * r.z);
      return Quat(r.w / n, r.x / n, r.y / n, r.z / n);
    }
    final th = math.acos(d);
    final s = math.sin(th);
    final a = math.sin((1 - t) * th) / s, c = math.sin(t * th) / s;
    return Quat(a * w + c * bb.w, a * x + c * bb.x, a * y + c * bb.y, a * z + c * bb.z);
  }
}

/// A regular dodecahedron with its faces numbered as the printed one:
/// face 1 on top, 2-6 around it, 7-11 below and 12 at the bottom, so that
/// opposite faces add up to 13.
class Dodecahedron {
  Dodecahedron._(this.normals, this.faces);

  /// Outward unit normal of face n at index n - 1.
  final List<V3> normals;

  /// Vertices of face n (at index n - 1), in order around the face.
  final List<List<V3>> faces;

  static final Dodecahedron instance = _build();

  static Dodecahedron _build() {
    final theta = math.atan(2); // angle between neighbouring face normals
    V3 dir(double polar, double azimuthDeg) {
      final a = azimuthDeg * math.pi / 180;
      return V3(math.sin(polar) * math.cos(a), math.sin(polar) * math.sin(a), math.cos(polar));
    }

    final normals = List<V3>.filled(12, const V3(0, 0, 1));
    normals[0] = const V3(0, 0, 1);
    normals[11] = const V3(0, 0, -1);
    for (var k = 0; k < 5; k++) {
      final azimuth = 90.0 + 72 * k;
      normals[1 + k] = dir(theta, azimuth); // faces 2-6
      // The face opposite face (2 + k) is 13 - (2 + k) = 11 - k.
      normals[10 - k] = dir(math.pi - theta, azimuth + 180);
    }

    // A vertex is where three mutually neighbouring faces meet.
    final cosNeighbour = math.cos(theta);
    bool neighbours(int a, int b) => (normals[a].dot(normals[b]) - cosNeighbour).abs() < 1e-6;
    final vertexFaces = <(V3, Set<int>)>[];
    for (var i = 0; i < 12; i++) {
      for (var j = i + 1; j < 12; j++) {
        if (!neighbours(i, j)) continue;
        for (var k = j + 1; k < 12; k++) {
          if (!neighbours(i, k) || !neighbours(j, k)) continue;
          vertexFaces.add(((normals[i] + normals[j] + normals[k]).unit, {i, j, k}));
        }
      }
    }
    final faces = <List<V3>>[];
    for (var f = 0; f < 12; f++) {
      final n = normals[f];
      final ref = (n.cross(const V3(0.3, 0.5, 0.8))).unit;
      final ref2 = n.cross(ref);
      final verts = [for (final (v, fs) in vertexFaces) if (fs.contains(f)) v]
        ..sort((a, b) => math.atan2(a.dot(ref2), a.dot(ref)).compareTo(math.atan2(b.dot(ref2), b.dot(ref))));
      faces.add(verts);
    }
    return Dodecahedron._(normals, faces);
  }

  /// Where the face that is up on the table points in the drawing: up and
  /// towards the viewer, as seen from the front and a little above.
  static final V3 upInView = V3(0, math.sin(42 * math.pi / 180), math.cos(42 * math.pi / 180));

  /// Rotation of the drawing with face [face] up.
  Quat orientationFor(int face) {
    final n = normals[(face - 1).clamp(0, 11)];
    final align = Quat.between(n, upInView);
    // Turn about the up axis so the drawing does not look the same for
    // every face (and the numbers sit at different places).
    return Quat.axisAngle(upInView, 0.35 * face) * align;
  }
}

/// Paints the dodecahedron with face [face] up (highlighted), turning
/// smoothly from the previous face.
class DodecahedronView extends StatefulWidget {
  const DodecahedronView({super.key, required this.face, this.size = 260});

  final int face;
  final double size;

  @override
  State<DodecahedronView> createState() => _DodecahedronViewState();
}

class _DodecahedronViewState extends State<DodecahedronView> with SingleTickerProviderStateMixin {
  late final AnimationController _turn = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );
  late Quat _from = Dodecahedron.instance.orientationFor(widget.face);
  late Quat _to = _from;

  @override
  void didUpdateWidget(DodecahedronView old) {
    super.didUpdateWidget(old);
    if (old.face != widget.face) {
      _from = _from.slerp(_to, Curves.easeInOut.transform(_turn.value));
      _to = Dodecahedron.instance.orientationFor(widget.face);
      _turn.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _turn,
      builder: (context, _) => CustomPaint(
        size: Size.square(widget.size),
        painter: DodecahedronPainter(
          orientation: _from.slerp(_to, Curves.easeInOut.transform(_turn.value)),
          face: widget.face,
        ),
      ),
    );
  }
}

class DodecahedronPainter extends CustomPainter {
  DodecahedronPainter({required this.orientation, required this.face});

  final Quat orientation;
  final int face;

  static const _accent = Color(0xFF22D3EE);
  static const _light = V3(-0.3, 0.6, 0.75);

  @override
  void paint(Canvas canvas, Size size) {
    final d = Dodecahedron.instance;
    final center = size.center(Offset.zero);
    final scale = size.shortestSide * 0.36;
    Offset project(V3 v) => center + Offset(v.x * scale, -v.y * scale);

    final visible = <(int, double)>[];
    for (var f = 0; f < 12; f++) {
      final n = orientation.rotate(d.normals[f]);
      if (n.z > 0.02) visible.add((f, n.z));
    }
    visible.sort((a, b) => a.$2.compareTo(b.$2));

    final light = _light.unit;
    for (final (f, _) in visible) {
      final n = orientation.rotate(d.normals[f]);
      final pts = [for (final v in d.faces[f]) project(orientation.rotate(v))];
      final path = Path()..addPolygon(pts, true);
      final shade = (0.35 + 0.65 * n.dot(light).clamp(0.0, 1.0));
      final up = f + 1 == face;
      final base = up ? _accent : const Color(0xFF94A3B8);
      canvas.drawPath(
        path,
        Paint()..color = Color.lerp(const Color(0xFF0F172A), base, shade)!,
      );
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = up ? 3 : 1.5
          ..color = up ? Colors.white : const Color(0xFF0F172A),
      );
      final c = project(orientation.rotate(d.normals[f] * 0.8));
      final tp = TextPainter(
        text: TextSpan(
          text: '${f + 1}',
          style: TextStyle(
            color: up ? Colors.black : Colors.white,
            fontSize: scale * 0.32 * (0.55 + 0.45 * n.z),
            fontWeight: FontWeight.w900,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(DodecahedronPainter old) =>
      old.orientation != orientation || old.face != face;
}
