import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../analytics_engine.dart';
import '../app_localizations.dart';
import '../visual_widgets.dart';

class RevenuePieChart extends StatelessWidget {
  final AnalyticsEngine engine;
  final Animation<double> fadeAnimation;
  final Animation<double> slideAnimation;

  const RevenuePieChart({
    Key? key,
    required this.engine,
    required this.fadeAnimation,
    required this.slideAnimation,
  }) : super(key: key);

  Widget _buildEmptyChart(String message) {
    return Container(
      height: 200,
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.pie_chart_outline, size: 48, color: Colors.grey[600]),
            const SizedBox(height: 16),
            Text(
              message,
              style: TextStyle(color: Colors.grey[500], fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  Color _getChartColor(int index) {
    const colors = [
      Color(0xFF4F46E5), // Indigo
      Color(0xFF0EA5E9), // Light Blue
      Color(0xFF10B981), // Emerald
      Color(0xFFF59E0B), // Amber
      Color(0xFF8B5CF6), // Purple
      Color(0xFFEC4899), // Pink
      Color(0xFF14B8A6), // Teal
      Color(0xFFF43F5E), // Rose
      Color(0xFF6366F1), // Violet
      Color(0xFFF97316), // Orange
      Color(0xFF3B82F6), // Blue
      Color(0xFF84CC16), // Lime
      Color(0xFF06B6D4), // Cyan
      Color(0xFFEAB308), // Yellow
      Color(0xFFA855F7), // Purple variant
      Color(0xFF22C55E), // Green
    ];
    return colors[index % colors.length];
  }
  String _formatCompactNumber(double number) {
    if (number >= 10000000) return '${(number / 10000000).toStringAsFixed(2)}Cr';
    if (number >= 100000) return '${(number / 100000).toStringAsFixed(2)}L';
    if (number >= 1000) return '${(number / 1000).toStringAsFixed(1)}K';
    return number.toStringAsFixed(0);
  }

  Widget _Badge({required IconData icon, required double size, required Color color}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: color, width: 2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            offset: const Offset(0, 3),
            blurRadius: 5,
          ),
        ],
      ),
      padding: EdgeInsets.all(size * .15),
      child: Center(
        child: Icon(icon, size: size * .5, color: color),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final monthly = engine.salesByMonthCache.entries
        .where((e) => e.value > 0)
        .toList()
      ..sort((a, b) => b.key.compareTo(a.key));

    if (monthly.isEmpty) {
      return _buildEmptyChart('No monthly revenue data');
    }

    final visible = monthly.take(8).toList();
    final total = visible.fold<double>(0, (sum, e) => sum + e.value);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return AnimatedBuilder(
      animation: fadeAnimation,
      builder: (context, child) => Opacity(
        opacity: fadeAnimation.value,
        child: Transform.translate(
          offset: Offset(0, slideAnimation.value),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: isDark ? Colors.white.withValues(alpha: 0.03) : Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: isDark ? Colors.white.withValues(alpha: 0.1) : Colors.grey.withValues(alpha: 0.2)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Monthly Revenue Distribution', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: isDark ? Colors.white : const Color(0xFF1F2937))),
                    const Icon(Icons.pie_chart, color: AppColors.secondary, size: 20),
                  ],
                ),
                const SizedBox(height: 18),
                SizedBox(
                  height: 250,
                  child: PieChart(
                    PieChartData(
                      centerSpaceRadius: 52,
                      sectionsSpace: 3,
                      sections: [
                        for (var i = 0; i < visible.length; i++)
                          PieChartSectionData(
                            value: visible[i].value,
                            title: total > 0 ? '${(visible[i].value / total * 100).toStringAsFixed(0)}%' : '0%',
                            radius: 88,
                            color: _getChartColor(i),
                            titleStyle: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    for (var i = 0; i < visible.length; i++)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(width: 9, height: 9, decoration: BoxDecoration(color: _getChartColor(i), shape: BoxShape.circle)),
                          const SizedBox(width: 5),
                          Text('${visible[i].key}: ₹${_formatCompactNumber(visible[i].value)}', style: TextStyle(fontSize: 11, color: isDark ? Colors.white70 : Colors.black87)),
                        ],
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
