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
    if (engine.filteredSalesCache.isEmpty) {
      return _buildEmptyChart(AppLocalizations.of(context).noProductData);
    }

    final productData = engine.productAnalyticsCache;
    final products = productData.entries.toList();
    products.sort((a, b) => ((b.value['percentage'] as double?) ?? 0.0)
        .compareTo((a.value['percentage'] as double?) ?? 0.0));
    final topProducts = products.take(5).toList();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return AnimatedBuilder(
      animation: fadeAnimation,
      builder: (context, child) {
        return Opacity(
          opacity: fadeAnimation.value,
          child: Transform.translate(
            offset: Offset(0, slideAnimation.value),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: isDark ? Colors.white.withValues(alpha: 0.03) : Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: isDark ? Colors.white.withValues(alpha: 0.1) : Colors.grey.withValues(alpha: 0.2),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.05),
                    blurRadius: 10,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: AppColors.secondary.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppColors.secondary.withValues(alpha: 0.3)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.pie_chart, color: AppColors.secondary, size: 16),
                            const SizedBox(width: 8),
                            Text(
                              AppLocalizations.of(context).revenueShare,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: AppColors.secondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Text(
                    AppLocalizations.of(context).topProductsByRevenue,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: isDark ? Colors.white : const Color(0xFF1F2937),
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    height: 220,
                    child: Stack(
                      children: [
                        PieChart(
                          PieChartData(
                            sectionsSpace: 4,
                            centerSpaceRadius: 55,
                            sections: topProducts.asMap().entries.map((entry) {
                              final index = entry.key;
                              final product = entry.value;
                              final double value = (product.value['percentage'] as double?) ?? 0.0;
                              final color = _getChartColor(index);
                              if (value <= 0) return null; // FIX: Don't show 0% segments
                              
                              return PieChartSectionData(
                                color: color,
                                value: value,
                                title: '${value.toStringAsFixed(0)}%',
                                radius: 55.0,
                                titleStyle: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                  shadows: [
                                    Shadow(color: Colors.black, blurRadius: 6, offset: Offset(1, 1)),
                                    Shadow(color: Colors.black, blurRadius: 6, offset: Offset(-1, -1)),
                                  ],
                                ),
                                badgeWidget: _Badge(
                                  icon: Icons.inventory_2,
                                  size: 32,
                                  color: color,
                                ),
                                badgePositionPercentageOffset: 1.15,
                              );
                            }).whereType<PieChartSectionData>().toList(),
                          ),
                        ),
                        Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                '₹${_formatCompactNumber(engine.filteredTotalSales)}',
                                style: TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.w900,
                                  color: isDark ? Colors.white : const Color(0xFF1F2937),
                                ),
                              ),
                              Text(
                                AppLocalizations.of(context).total,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.grey[500],
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),
                  // Premium Legend
                  Wrap(
                    spacing: 16,
                    runSpacing: 16,
                    alignment: WrapAlignment.center,
                    children: topProducts.asMap().entries.map((entry) {
                      final index = entry.key;
                      final product = entry.value;
                      final double perc = (product.value['percentage'] as double?) ?? 0.0;
                      final double val = (product.value['total'] as double?) ?? 0.0;
                      if (perc <= 0) return const SizedBox.shrink(); // Hide 0% in legend too
                      return Container(
                        width: (MediaQuery.of(context).size.width - 100) / 2,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: isDark ? AppColors.surfaceDark : Colors.grey[50],
                          border: Border.all(
                            color: isDark ? Colors.black : Colors.grey[200]!,
                          ),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(
                                color: _getChartColor(index),
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: _getChartColor(index).withValues(alpha: 0.4),
                                    blurRadius: 4,
                                    spreadRadius: 1,
                                  )
                                ],
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    product.value['display_name']?.toString() ?? product.key,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      color: isDark ? Colors.black : Colors.grey[800],
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 2),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        '${perc.toStringAsFixed(1)}%',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: _getChartColor(index),
                                        ),
                                      ),
                                      Text(
                                        '₹${_formatCompactNumber(val)}',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                          color: isDark ? Colors.grey[400] : Colors.grey[600],
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
