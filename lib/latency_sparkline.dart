import 'package:flutter/material.dart';

class LatencySparkline extends StatelessWidget {
  final List<int> samples;
  final double width;
  final double height;

  const LatencySparkline({
    super.key,
    required this.samples,
    this.width = 60,
    this.height = 16,
  });

  @override
  Widget build(BuildContext context) {
    if (samples.isEmpty) {
      return Tooltip(
        message: 'No health data yet',
        child: SizedBox(width: width, height: height),
      );
    }
    final hasFailure = samples.any((s) => s < 0);
    final reachable = samples.where((s) => s >= 0).toList();
    final hasSlow = reachable.any((s) => s >= 500);
    final color = hasFailure
        ? Colors.redAccent
        : hasSlow
            ? Colors.orangeAccent
            : Colors.greenAccent;
    final tooltipLines = <String>[];
    final start = samples.length > 12 ? samples.length - 12 : 0;
    for (var i = start; i < samples.length; i++) {
      final s = samples[i];
      final stamp = '${(i * 30) ~/ 60}m${(i * 30) % 60}s ago';
      tooltipLines.add(s < 0 ? '$stamp: down' : '$stamp: ${s}ms');
    }
    return Tooltip(
      message: tooltipLines.reversed.join('\n'),
      waitDuration: const Duration(milliseconds: 200),
      preferBelow: false,
      child: SizedBox(
        width: width,
        height: height,
        child: CustomPaint(
          painter: _SparklinePainter(
            samples: samples,
            color: color,
            baselineColor: hasFailure ? Colors.redAccent : Colors.white24,
          ),
        ),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final List<int> samples;
  final Color color;
  final Color baselineColor;

  _SparklinePainter({
    required this.samples,
    required this.color,
    required this.baselineColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.isEmpty) return;
    final n = samples.length;
    final maxSample = samples.where((s) => s >= 0).fold<int>(100, (m, s) => s > m ? s : m);
    final stepX = n == 1 ? 0.0 : size.width / (n - 1);

    final baselinePaint = Paint()
      ..color = baselineColor
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, size.height - 0.5), Offset(size.width, size.height - 0.5), baselinePaint);

    var linePath = Path();
    final failPaint = Paint()..color = Colors.redAccent;
    var started = false;
    for (var i = 0; i < n; i++) {
      final s = samples[i];
      final x = i * stepX;
      if (s < 0) {
        if (started) {
          _strokePath(canvas, linePath, color);
          linePath = Path();
          started = false;
        }
        canvas.drawCircle(Offset(x, size.height - 1.5), 1.5, failPaint);
      } else {
        final y = size.height - (s / maxSample) * (size.height - 2) - 1;
        if (!started) {
          linePath.moveTo(x, y);
          started = true;
        } else {
          linePath.lineTo(x, y);
        }
      }
    }
    if (started) _strokePath(canvas, linePath, color);
  }

  void _strokePath(Canvas canvas, Path path, Color c) {
    final paint = Paint()
      ..color = c
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) =>
      old.samples != samples || old.color != color;
}
