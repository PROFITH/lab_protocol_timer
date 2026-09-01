import 'package:flutter/material.dart';

class ChartSeries {
  final List<double> points;
  final Color color;
  final String label;

  ChartSeries({
    required this.points,
    required this.color,
    required this.label,
  });
}

class SensorChartCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final String currentValue;
  final String unit;
  final List<ChartSeries> seriesList;
  final Widget? trailingAction; // Aquí colocaremos el Toggle de opciones

  const SensorChartCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.currentValue,
    required this.unit,
    required this.seriesList,
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
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
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
                  Text(
                    subtitle,
                    style: const TextStyle(color: Colors.white38, fontSize: 10),
                  ),
                ],
              ),
              Row(
                children: [
                  if (trailingAction != null) ...[
                    trailingAction!,
                    const SizedBox(width: 12),
                  ],
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        currentValue,
                        style: TextStyle(
                          color: primaryColor,
                          fontSize: 14,
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(width: 3),
                      Text(
                        unit,
                        style: const TextStyle(color: Colors.white38, fontSize: 10),
                      ),
                    ],
                  ),
                ],
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
                child: CustomPaint(
                  painter: _MultiWaveformPainter(
                    seriesList: seriesList,
                    unit: unit,
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

class _MultiWaveformPainter extends CustomPainter {
  final List<ChartSeries> seriesList;
  final String unit;

  _MultiWaveformPainter({
    required this.seriesList,
    required this.unit,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const double rightPadding = 45.0;
    final double chartWidth = size.width - rightPadding;

    if (seriesList.isEmpty) return;

    // Calcular min y max globales entre todas las series activas para escalar el eje Y
    double globalMin = double.infinity;
    double globalMax = double.negativeInfinity;

    for (var series in seriesList) {
      if (series.points.isNotEmpty) {
        double sMin = series.points.reduce((a, b) => a < b ? a : b);
        double sMax = series.points.reduce((a, b) => a > b ? a : b);
        if (sMin < globalMin) globalMin = sMin;
        if (sMax > globalMax) globalMax = sMax;
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

    _drawAxisLabelsAndGrid(canvas, size, chartWidth, globalMin, globalMax);

    // Dibujar cada serie de datos
    for (var series in seriesList) {
      if (series.points.isEmpty) continue;

      final paint = Paint()
        ..color = series.color
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;

      final path = Path();
      double range = globalMax - globalMin;
      final dx = chartWidth / (series.points.length > 1 ? series.points.length - 1 : 1);

      for (int i = 0; i < series.points.length; i++) {
        final normalizedY = size.height -
            ((series.points[i] - globalMin) / range) * (size.height * 0.8) -
            (size.height * 0.1);
        final x = i * dx;

        if (i == 0) {
          path.moveTo(x, normalizedY);
        } else {
          path.lineTo(x, normalizedY);
        }
      }

      canvas.drawPath(path, paint);
    }
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
  bool shouldRepaint(covariant _MultiWaveformPainter oldDelegate) {
    return oldDelegate.seriesList != seriesList;
  }
}