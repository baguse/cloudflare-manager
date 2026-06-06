import 'package:flutter/material.dart';

class TunnelHeatmap extends StatelessWidget {
  final Map<String, int> dayCounts;
  final int maxCount;

  const TunnelHeatmap({
    super.key,
    required this.dayCounts,
    required this.maxCount,
  });

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = _dateKey(now);
    final cells = <Widget>[];

    for (var d = 29; d >= 0; d--) {
      final date = _dateKey(now.subtract(Duration(days: d)));
      final count = dayCounts[date] ?? 0;
      final intensity = maxCount > 0 ? count / maxCount : 0.0;
      final color = _heatColor(intensity, date == today ? 0.25 : 0.0);

      cells.add(Tooltip(
        message: '$date — $count requests',
        child: Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
            border: date == today ? Border.all(color: Colors.white.withOpacity(0.3), width: 1) : null,
          ),
        ),
      ));

      if (d > 0 && (30 - d) % 7 == 0) {
        cells.add(const SizedBox(width: 3));
      }
    }

    final total = dayCounts.values.fold<int>(0, (a, b) => a + b);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('Requests (30 days)', style: TextStyle(fontSize: 10, color: Colors.grey)),
            const Spacer(),
            Text(total > 0 ? '$total requests' : 'no data', style: const TextStyle(fontSize: 10, color: Colors.grey)),
          ],
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 2,
          runSpacing: 2,
          children: cells,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Text('Less', style: TextStyle(fontSize: 9, color: Colors.grey)),
            const SizedBox(width: 4),
            _legendSwatch(),
            const SizedBox(width: 4),
            const Text('More', style: TextStyle(fontSize: 9, color: Colors.grey)),
          ],
        ),
      ],
    );
  }

  Widget _legendSwatch() {
    const steps = [0.0, 0.25, 0.5, 0.75, 1.0];
    return Row(
      children: steps.map((i) => Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: _heatColor(i, 0),
          borderRadius: BorderRadius.circular(2),
        ),
      )).toList(),
    );
  }

  Color _heatColor(double intensity, double todayBonus) {
    final base = Color.lerp(
      const Color(0xFF1E293B),
      const Color(0xFFF6821F),
      (intensity * 0.8 + todayBonus).clamp(0, 1),
    )!;
    if (intensity == 0) return const Color(0xFF1E293B);
    return base;
  }

  String _dateKey(DateTime d) {
    return d.toIso8601String().substring(0, 10);
  }
}
