// Renders every activity figure to PNG for a visual check:
// FIGURES_OUT=/some/dir flutter test test/tools/render_figures_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lab_protocol_timer/models/activity_battery.dart';
import 'package:lab_protocol_timer/session/activity_figure.dart';

void main() {
  final out = Platform.environment['FIGURES_OUT'];

  testWidgets('render figures', (tester) async {
    if (out == null) return;
    final key = GlobalKey();
    const times = [0.0, 0.15, 0.3, 0.45, 0.6];
    await tester.binding.setSurfaceSize(const Size(1500, 3200));
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: key,
          child: Container(
            color: const Color(0xFF0B0F19),
            child: Column(
              children: [
                for (final a in activityAnimations)
                  SizedBox(
                    height: 200,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(width: 120, child: Text(a, style: const TextStyle(color: Colors.white, fontSize: 14))),
                        Expanded(
                          child: CustomPaint(
                            painter: FigurePainter(animation: a, seconds: 0, moving: false, color: Colors.orangeAccent, propColor: const Color(0x66FFFFFF)),
                          ),
                        ),
                        for (final t in times)
                          Expanded(
                            child: CustomPaint(
                              painter: FigurePainter(animation: a, seconds: t, moving: true, color: Colors.white, propColor: const Color(0x66FFFFFF)),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      final boundary = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 0.6);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$out/figures.png').writeAsBytes(bytes!.buffer.asUint8List());
    });
  });
}
