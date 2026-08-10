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
    try {
      if (engine.filteredSalesCache.isEmpty) {
        return _buildEmptyChart(AppLocalizations.of(context).noProductData);
      }

      final productData = engine.productAnalyticsCache;
      if (productData == null || productData.isEmpty) {
        return _buildEmptyChart(AppLocalizations.of(context).noProductData);
      }

      final totalQty = productData.values.fold<int>(0, (sum, p) {
        final qty = p?['quantity'];
        if (qty is int) return sum + qty;
        if (qty is num) return sum + qty.toInt();
        return sum;
      });
      
      final quantityPercentages = <String, double>{};
      final displayNames = <String, String>{}; // FIX: Store display names

      productData.forEach((key, data) {
        final qty = data?['quantity'];
        double qtyVal = 0.0;
        if (qty is num) qtyVal = qty.toDouble();
        
        final name = data?['display_name']?.toString() ?? 'Unknown';
        quantityPercentages[key] = (totalQty > 0) ? (qtyVal / totalQty) * 100 : 0.0;
        displayNames[key] = name;
      });

      // Sort by percentage and take top 6
      var topEntries = quantityPercentages.entries.toList();
      topEntries.sort((a, b) => b.value.compareTo(a.value));
      final List<MapEntry<String, double>> topProducts = [];
      
      for (var entry in topEntries.take(6)) {
        topProducts.add(MapEntry(displayNames[entry.key] ?? 'Unknown', entry.value));
      }

      // fl_chart RadarChart requires at least 3 data points – pad if needed
      while (topProducts.length < 3) {
        topProducts.add(const MapEntry('—', 0.0));
      }
      
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
                          color: AppColors.info.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppColors.info.withValues(alpha: 0.3)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.radar, color: AppColors.info, size: 16),
                            const SizedBox(width: 8),
                            Text(
                              AppLocalizations.of(context).quantityDistribution,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: AppColors.info,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(Icons.more_horiz, color: Colors.grey[500]),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Text(
                    AppLocalizations.of(context).volumeByProduct,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: const Color(0xFF1F2937),
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    height: 250,
                    child: RadarChart(
                      RadarChartData(
                        radarTouchData: RadarTouchData(enabled: true),
                        dataSets: [
                          RadarDataSet(
                            fillColor: AppColors.info.withValues(alpha: 0.25),
                            borderColor: AppColors.info,
                            entryRadius: 4,
                            borderWidth: 2,
                            dataEntries: topProducts.map((e) => RadarEntry(value: e.value)).toList(),
                          )
                        ],
                        radarBackgroundColor: isDark ? Colors.white.withValues(alpha: 0.02) : Colors.grey.withValues(alpha: 0.05),
                        borderData: FlBorderData(show: false),
                        radarBorderData: const BorderSide(color: Colors.transparent),
                        titlePositionPercentageOffset: 0.15,
                        titleTextStyle: TextStyle(
                          color: isDark ? Colors.grey[400] : Colors.grey[700],
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                        getTitle: (index, angle) {
                          if (index >= 0 && index < topProducts.length) {
                             final title = topProducts[index].key;
                             return RadarChartTitle(
                               text: title.length > 10 ? '${title.substring(0, 10)}..' : title,
                             );
                          }
                          return const RadarChartTitle(text: '');
                        },
                        tickCount: 4,
                        ticksTextStyle: const TextStyle(color: Colors.transparent, fontSize: 10),
                        tickBorderData: BorderSide(
                          color: isDark ? Colors.white.withValues(alpha: 0.1) : Colors.grey.withValues(alpha: 0.2),
                        ),
                        gridBorderData: BorderSide(
                          color: isDark ? Colors.white.withValues(alpha: 0.1) : Colors.grey.withValues(alpha: 0.2),
                          width: 1,
                        ),
                      ),
                      swapAnimationDuration: const Duration(milliseconds: 400),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                       Expanded(
                         child: _buildPremiumMiniCard(
                           context,
                           'Top Volume', 
                           topProducts.isNotEmpty ? topProducts.first.key : 'N/A', 
                           Icons.star, 
                           AppColors.primary
                         )
                       ),
                       const SizedBox(width: 12),
                       Expanded(
                         child: _buildPremiumMiniCard(
                           context,
                           'Total Volumes', 
                           '$totalQty', 
                           Icons.inventory_2, 
                           AppColors.info
                         )
                       ),
                    ],
                  )
                ],
              ),
            ),
          ),
        );
      },
    );
    } catch (e) {
    if (kDebugMode) debugPrint('Error building radar chart: $e');
      return _buildEmptyChart(AppLocalizations.of(context).noProductData);
    }
  }
}

