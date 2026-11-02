import 'package:flutter/material.dart';

import 'live_signal.dart';

class ChartSeries {
  final SignalBuffer buffer;
  final Color color;
  final String label;

  ChartSeries({
    required this.buffer,
    required this.color,
    required this.label,
  });
}

/// Live chart of one or more signals over the last [window].
///
/// The card repaints when [clock] ticks (once per screen frame with new
/// data), without rebuilding the monitor. The trace keeps every sample: each
/// pixel column draws the range between the lowest and highest sample that
/// fall in it, so peaks are never smoothed away.
class SensorChartCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final String Function() currentValue;
  final String unit;
  final List<ChartSeries> seriesList;
  final Duration window;
  final Listenable clock;
  final Widget? trailingAction; // Aquí colocaremos el Toggle de opciones

  const SensorChartCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.currentValue,
    required this.unit,
    required this.seriesList,
    required this.window,
    required this.clock,
    this.trailingAction,
  });

  @override
  Widget build(BuildContext context) {
    final primaryColor = seriesList.isNotEmpty ? seriesList.first.color : Colors.white;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: primaryColor, size: 18),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  subtitle,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white38, fontSize: 10),
                ),
              ),
              if (trailingAction != null) ...[
                trailingAction!,
                const SizedBox(width: 12),
              ],
              ListenableBuilder(
                listenable: clock,
                builder: (context, _) => Text(
                  currentValue(),
                  style: TextStyle(
                    color: primaryColor,
                    fontSize: 14,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              const SizedBox(width: 3),
              Text(
                unit,
                style: const TextStyle(color: Colors.white38, fontSize: 10),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Container(
                color: const Color(0xFF0F172A),
                width: double.infinity,
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: LiveChartPainter(
                      seriesList: seriesList,
                      window: window,
                      repaint: clock,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class LiveChartPainter extends CustomPainter {
  final List<ChartSeries> seriesList;
  final Duration window;

  LiveChartPainter({
    required this.seriesList,
    required this.window,
    super.repaint,
  });

  static const double rightPadding = 45.0;

  @override
  void paint(Canvas canvas, Size size) {
    final chartWidth = size.width - rightPadding;
    if (seriesList.isEmpty || chartWidth <= 4) return;

    // The chart ends at the newest sample of any series.
    double? end;
    for (final series in seriesList) {
      final t = series.buffer.lastTime;
      if (t != null && (end == null || t > end)) end = t;
    }

    final columns = chartWidth.floor();
    final envelopes = <ColumnEnvelope>[];
    var globalMin = double.infinity;
    var globalMax = double.negativeInfinity;
    if (end != null) {
      for (final series in seriesList) {
        final envelope = columnEnvelope(
          series.buffer,
          columns: columns,
          endMicros: end,
          window: window,
        );
        envelopes.add(envelope);
        if (!envelope.isEmpty) {
          if (envelope.lowest < globalMin) globalMin = envelope.lowest;
          if (envelope.highest > globalMax) globalMax = envelope.highest;
        }
      }
    }

    if (globalMin == double.infinity) {
      globalMin = 0;
      globalMax = 1;
    }
    if (globalMin == globalMax) {
      globalMin -= 1;
      globalMax += 1;
    }

    _drawTimeGrid(canvas, size, chartWidth);
    _drawAxisLabelsAndGrid(canvas, size, chartWidth, globalMin, globalMax);

    final range = globalMax - globalMin;
    double y(double v) =>
        size.height - ((v - globalMin) / range) * (size.height * 0.8) - (size.height * 0.1);
    final dx = chartWidth / columns;

    for (var s = 0; s < envelopes.length; s++) {
      final envelope = envelopes[s];
      if (envelope.isEmpty) continue;

      final paint = Paint()
        ..color = seriesList[s].color
        ..strokeWidth = 1.2
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round;

      final path = Path();
      var started = false;
      for (var c = 0; c < columns; c++) {
        if (envelope.filled[c] == 0) continue;
        final x = (c + 0.5) * dx;
        if (!started) {
          path.moveTo(x, y(envelope.first[c]));
          started = true;
        } else {
          path.lineTo(x, y(envelope.first[c]));
        }
        if (envelope.min[c] != envelope.max[c]) {
          path.lineTo(x, y(envelope.min[c]));
          path.lineTo(x, y(envelope.max[c]));
        }
        path.lineTo(x, y(envelope.last[c]));
      }
      canvas.drawPath(path, paint);
    }
  }

  /// Vertical lines every second (windows up to 10 s), 10 s or 30 s.
  void _drawTimeGrid(Canvas canvas, Size size, double chartWidth) {
    final seconds = window.inMilliseconds / 1000.0;
    final step = seconds <= 10 ? 1.0 : (seconds <= 60 ? 10.0 : 30.0);
    final paint = Paint()
      ..color = Colors.white.withAlpha(10)
      ..strokeWidth = 1.0;
    for (var t = step; t < seconds; t += step) {
      final x = chartWidth * (1 - t / seconds);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    _drawText(
      canvas,
      '${seconds.toStringAsFixed(seconds < 10 ? 1 : 0)} s',
      4,
      size.height - 13,
    );
  }

  void _drawAxisLabelsAndGrid(Canvas canvas, Size size, double chartWidth, double minY, double maxY) {
    double midY = (minY + maxY) / 2;

    final gridPaint = Paint()
      ..color = Colors.white.withAlpha(15)
      ..strokeWidth = 1.0;

    final yMaxPos = size.height * 0.1;
    final yMidPos = size.height * 0.5;
    final yMinPos = size.height * 0.9;

    canvas.drawLine(Offset(0, yMaxPos), Offset(chartWidth, yMaxPos), gridPaint);
    canvas.drawLine(Offset(0, yMidPos), Offset(chartWidth, yMidPos), gridPaint);
    canvas.drawLine(Offset(0, yMinPos), Offset(chartWidth, yMinPos), gridPaint);

    _drawText(canvas, _formatValue(maxY), chartWidth + 6, yMaxPos - 6);
    _drawText(canvas, _formatValue(midY), chartWidth + 6, yMidPos - 6);
    _drawText(canvas, _formatValue(minY), chartWidth + 6, yMinPos - 6);
  }

  void _drawText(Canvas canvas, String text, double x, double y) {
    final textSpan = TextSpan(
      text: text,
      style: const TextStyle(
        color: Colors.white38,
        fontSize: 9,
        fontFamily: 'monospace',
      ),
    );
    final textPainter = TextPainter(
      text: textSpan,
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(canvas, Offset(x, y));
  }

  String _formatValue(double val) {
    if (val.abs() >= 1000) {
      return '${(val / 1000).toStringAsFixed(1)}k';
    }
    return val.toStringAsFixed(0);
  }

  @override
  bool shouldRepaint(covariant LiveChartPainter oldDelegate) {
    return oldDelegate.window != window ||
        oldDelegate.seriesList.length != seriesList.length ||
        [
          for (var i = 0; i < seriesList.length; i++)
            !identical(oldDelegate.seriesList[i].buffer, seriesList[i].buffer) ||
                oldDelegate.seriesList[i].color != seriesList[i].color,
        ].any((changed) => changed);
  }
}
