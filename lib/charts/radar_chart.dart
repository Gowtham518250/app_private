import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:fl_chart/fl_chart.dart';
import '../analytics_engine.dart';
import '../app_localizations.dart';
import '../visual_widgets.dart';

class RevenueRadarChart extends StatelessWidget {
  final AnalyticsEngine engine;
  final Animation<double> fadeAnimation;
  final Animation<double> slideAnimation;

  const RevenueRadarChart({
    Key? key,
    required this.engine,
    required this.fadeAnimation,
    required this.slideAnimation,
  }) : super(key: key);

  String _formatCompactNumber(double number) {
    if (number >= 10000000) return '${(number / 10000000).toStringAsFixed(2)}Cr';
    if (number >= 100000) return '${(number / 100000).toStringAsFixed(2)}L';
    if (number >= 1000) return '${(number / 1000).toStringAsFixed(1)}K';
    return number.toStringAsFixed(0);
  }

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
            Icon(Icons.radar, size: 48, color: Colors.grey[600]),
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

  Widget _buildPremiumMiniCard(BuildContext context, String label, String value, IconData icon, Color accent) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark 
            ? AppColors.surfaceDark 
            : Colors.grey[50],
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).brightness == Brightness.dark 
              ? Colors.white10 
              : Colors.grey[200]!
        )
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
           Row(
             children: [
               Icon(icon, size: 16, color: accent),
               const SizedBox(width: 6),
               Expanded(
                 child: Text(
                   label, 
                   style: TextStyle(
                     fontSize: 11, 
                     color: Colors.grey[500],
                     fontWeight: FontWeight.w600
                   ),
                   overflow: TextOverflow.ellipsis,
                 )
               )
             ],
           ),
           const SizedBox(height: 8),
           Text(
             value,
             style: TextStyle(
               fontSize: 16,
               fontWeight: FontWeight.w800,
               color: Theme.of(context).brightness == Brightness.dark                   ? const Color(0xFFE5E7EB) // Subtle light for dark mode
                   : const Color(0xFF1F2937),
             ),
             maxLines: 1,
             overflow: TextOverflow.ellipsis,
           )
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final monthly = engine.salesByMonthCache.entries
        .where((e) => e.value > 0)
        .toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    if (monthly.isEmpty) {
      return _buildEmptyChart('No monthly revenue data');
    }

    final visible = monthly.length > 6 ? monthly.sublist(monthly.length - 6) : monthly;
    final maxValue = visible.fold<double>(0, (m, e) => e.value > m ? e.value : m);
    final normalizedMax = maxValue <= 0 ? 1.0 : maxValue;

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
                    Text('Monthly Revenue Performance', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: isDark ? Colors.white : const Color(0xFF1F2937))),
                    const Icon(Icons.radar, color: AppColors.info, size: 20),
                  ],
                ),
                const SizedBox(height: 18),
                SizedBox(
                  height: 280,
                  child: RadarChart(
                    RadarChartData(
                      radarTouchData: RadarTouchData(enabled: true),
                      tickCount: 4,
                      ticksTextStyle: const TextStyle(fontSize: 9, color: Colors.grey),
                      tickBorderData: BorderSide(color: Colors.grey.withValues(alpha: 0.25)),
                      gridBorderData: BorderSide(color: Colors.grey.withValues(alpha: 0.3)),
                      dataSets: [
                        RadarDataSet(
                          fillColor: AppColors.info.withValues(alpha: 0.25),
                          borderColor: AppColors.info,
                          entryRadius: 4,
                          borderWidth: 2,
                          dataEntries: [
                            for (final e in visible)
                              RadarEntry(value: (e.value / normalizedMax) * 100),
                          ],
                        ),
                      ],
                      getTitle: (index, angle) => RadarChartTitle(text: visible[index].key),
                      titleTextStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
                      titlePositionPercentageOffset: 0.2,
                      borderData: FlBorderData(show: false),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Text('Max monthly revenue: ₹${_formatCompactNumber(maxValue)}', style: TextStyle(fontSize: 12, color: isDark ? Colors.white70 : Colors.black54)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
