import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/price_history_service.dart';

/// Time range presets for the range selector chips.
enum ChartRange {
  week('7D', 7),
  month('1M', 30),
  threeMonths('3M', 90),
  sixMonths('6M', 180),
  year('1Y', 365),
  all('All', 0);

  final String label;
  final int days;
  const ChartRange(this.label, this.days);
}

/// Interactive line chart with native fl_chart pinch-to-zoom and pan.
///
/// Receives hourly data from Steam. Uses fl_chart's built-in
/// FlTransformationConfig for smooth zoom/pan. Range chips filter
/// the data to preset windows.
class PriceChart extends StatefulWidget {
  final List<PriceHistoryPoint> data;

  const PriceChart({super.key, required this.data});

  @override
  State<PriceChart> createState() => _PriceChartState();
}

class _PriceChartState extends State<PriceChart> {
  ChartRange _selectedRange = ChartRange.month;
  int? _touchedIndex;
  late TransformationController _transformController;

  /// Daily-aggregated version of the full dataset.
  late List<PriceHistoryPoint> _dailyData;

  @override
  void initState() {
    super.initState();
    _transformController = TransformationController();
    _dailyData = _aggregateDaily(widget.data);
  }

  @override
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(PriceChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data) {
      _dailyData = _aggregateDaily(widget.data);
    }
  }

  /// Filter data to the selected time range.
  List<PriceHistoryPoint> _filterByRange(List<PriceHistoryPoint> data) {
    if (_selectedRange == ChartRange.all || _selectedRange.days == 0) {
      return data;
    }
    final cutoff =
        DateTime.now().subtract(Duration(days: _selectedRange.days));
    return data.where((p) => p.date.isAfter(cutoff)).toList();
  }

  /// Aggregate hourly points to daily (median price, total volume).
  List<PriceHistoryPoint> _aggregateDaily(List<PriceHistoryPoint> points) {
    if (points.isEmpty) return points;

    final byDay = <String, List<PriceHistoryPoint>>{};
    for (final p in points) {
      final key = '${p.date.year}-${p.date.month}-${p.date.day}';
      byDay.putIfAbsent(key, () => []).add(p);
    }

    final daily = <PriceHistoryPoint>[];
    for (final entry in byDay.entries) {
      final dayPoints = entry.value;
      dayPoints.sort((a, b) => a.price.compareTo(b.price));
      final medianPrice = dayPoints[dayPoints.length ~/ 2].price;
      final totalVolume = dayPoints.fold(0, (sum, p) => sum + p.volume);

      daily.add(PriceHistoryPoint(
        date: DateTime.utc(
          dayPoints.first.date.year,
          dayPoints.first.date.month,
          dayPoints.first.date.day,
        ),
        price: medianPrice,
        volume: totalVolume,
      ));
    }
    daily.sort((a, b) => a.date.compareTo(b.date));
    return daily;
  }

  /// Get display-ready data with appropriate granularity.
  List<PriceHistoryPoint> _getDisplayData() {
    final filtered = _filterByRange(widget.data);
    if (filtered.isEmpty) return filtered;

    final isShortRange = _selectedRange == ChartRange.week ||
        _selectedRange == ChartRange.month;

    if (isShortRange) {
      final firstDate = filtered.first.date;
      final lastDate = filtered.last.date;
      final daySpan =
          lastDate.difference(firstDate).inDays.clamp(1, 9999);
      final avgTradesPerDay = filtered.length / daySpan;

      if (avgTradesPerDay >= 10) {
        return filtered;
      }
    }

    // Daily for longer ranges or low volume
    return _filterByRange(_dailyData);
  }

  @override
  Widget build(BuildContext context) {
    final data = _getDisplayData();

    if (data.isEmpty) {
      return SizedBox(
        height: 200,
        child: Center(
          child: Text(
            'No price data for this period',
            style: TextStyle(color: Colors.grey[600]),
          ),
        ),
      );
    }

    final spots = <FlSpot>[];
    for (int i = 0; i < data.length; i++) {
      spots.add(FlSpot(i.toDouble(), data[i].price));
    }

    final prices = data.map((p) => p.price).toList();
    final minPrice = prices.reduce((a, b) => a < b ? a : b);
    final maxPrice = prices.reduce((a, b) => a > b ? a : b);
    final priceRange = maxPrice - minPrice;
    final padding = priceRange > 0 ? priceRange * 0.1 : maxPrice * 0.1;

    final firstPrice = data.first.price;
    final lastPrice = data.last.price;
    final priceChange = lastPrice - firstPrice;
    final percentChange =
        firstPrice > 0 ? (priceChange / firstPrice) * 100 : 0.0;
    final isPositive = priceChange >= 0;
    final lineColor = isPositive ? Colors.greenAccent : Colors.redAccent;

    final totalDays = widget.data.isEmpty
        ? 1
        : widget.data.last.date
            .difference(widget.data.first.date)
            .inDays
            .clamp(1, 99999);
    final isHourly = data.length > math.max(_selectedRange.days > 0 ? _selectedRange.days : totalDays, 1) * 1.5;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Price summary
        Row(
          children: [
            Text(
              '\$${lastPrice.toStringAsFixed(2)}',
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: lineColor.withAlpha(30),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '${isPositive ? '+' : ''}${percentChange.toStringAsFixed(1)}%',
                style: TextStyle(
                  color: lineColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const Spacer(),
            Text(
              isHourly ? 'Hourly' : 'Daily',
              style: TextStyle(color: Colors.grey[600], fontSize: 11),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Chart with native fl_chart zoom/pan
        SizedBox(
          height: 200,
          child: LineChart(
            LineChartData(
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                horizontalInterval: priceRange > 0
                    ? (priceRange / 4).clamp(0.01, double.infinity)
                    : maxPrice / 4,
                getDrawingHorizontalLine: (value) => FlLine(
                  color: Colors.white.withAlpha(10),
                  strokeWidth: 1,
                ),
              ),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false)),
                rightTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false)),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 52,
                    getTitlesWidget: (value, meta) {
                      if (value == meta.min || value == meta.max) {
                        return const SizedBox.shrink();
                      }
                      final label = value >= 1000
                          ? '\$${(value / 1000).toStringAsFixed(1)}k'
                          : '\$${value.toStringAsFixed(value >= 100 ? 0 : 2)}';
                      return Text(
                        label,
                        style: TextStyle(
                          color: Colors.grey[600],
                          fontSize: 10,
                        ),
                      );
                    },
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 24,
                    interval: (data.length / 4)
                        .ceilToDouble()
                        .clamp(1, double.infinity),
                    getTitlesWidget: (value, meta) {
                      final index = value.toInt();
                      if (index < 0 || index >= data.length) {
                        return const SizedBox.shrink();
                      }
                      final date = data[index].date;
                      final DateFormat format;
                      if (isHourly && (_selectedRange.days <= 7)) {
                        format = DateFormat('d/M HH:mm');
                      } else if (_selectedRange.days <= 90 &&
                          _selectedRange.days > 0) {
                        format = DateFormat('MMM d');
                      } else {
                        format = DateFormat('MMM yy');
                      }
                      return Text(
                        format.format(date),
                        style: TextStyle(
                          color: Colors.grey[600],
                          fontSize: 10,
                        ),
                      );
                    },
                  ),
                ),
              ),
              borderData: FlBorderData(show: false),
              minY: (minPrice - padding).clamp(0, double.infinity),
              maxY: maxPrice + padding,
              extraLinesData: ExtraLinesData(
                verticalLines: _touchedIndex != null &&
                        _touchedIndex! >= 0 &&
                        _touchedIndex! < data.length
                    ? [
                        VerticalLine(
                          x: _touchedIndex!.toDouble(),
                          color: Colors.white.withAlpha(40),
                          strokeWidth: 1,
                          dashArray: [4, 4],
                        ),
                      ]
                    : [],
              ),
              lineBarsData: [
                LineChartBarData(
                  spots: spots,
                  isCurved: true,
                  curveSmoothness: 0.2,
                  color: lineColor,
                  barWidth: 2,
                  isStrokeCapRound: true,
                  dotData: const FlDotData(show: false),
                  belowBarData: BarAreaData(
                    show: true,
                    color: lineColor.withAlpha(20),
                  ),
                ),
              ],
              showingTooltipIndicators: _touchedIndex != null &&
                      _touchedIndex! >= 0 &&
                      _touchedIndex! < data.length
                  ? [
                      ShowingTooltipIndicators([
                        LineBarSpot(
                          LineChartBarData(spots: spots),
                          0,
                          spots[_touchedIndex!],
                        ),
                      ]),
                    ]
                  : [],
              lineTouchData: LineTouchData(
                handleBuiltInTouches: false,
                touchCallback: (event, response) {
                  if (event is FlTapUpEvent &&
                      response?.lineBarSpots != null &&
                      response!.lineBarSpots!.isNotEmpty) {
                    setState(() {
                      _touchedIndex =
                          response.lineBarSpots!.first.x.toInt();
                    });
                  }
                },
                touchTooltipData: LineTouchTooltipData(
                  getTooltipColor: (_) => const Color(0xFF25253E),
                  getTooltipItems: (touchedSpots) {
                    return touchedSpots.map((spot) {
                      final index = spot.x.toInt();
                      if (index < 0 || index >= data.length) return null;
                      final point = data[index];
                      final dateFormat = isHourly
                          ? DateFormat('MMM d, yyyy HH:mm')
                          : DateFormat('MMM d, yyyy');
                      return LineTooltipItem(
                        '\$${point.price.toStringAsFixed(2)}\n${dateFormat.format(point.date)}\n${point.volume} sold',
                        const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      );
                    }).toList();
                  },
                ),
              ),
            ),
            transformationConfig: FlTransformationConfig(
              scaleAxis: FlScaleAxis.horizontal,
              minScale: 1.0,
              maxScale: 25.0,
              transformationController: _transformController,
            ),
          ),
        ),
        const SizedBox(height: 4),

        // Minimap — always visible, tap to navigate when zoomed
        _Minimap(
          spots: spots,
          lineColor: lineColor,
          minY: (minPrice - padding).clamp(0, double.infinity),
          maxY: maxPrice + padding,
          transformController: _transformController,
        ),
        const SizedBox(height: 8),

        // Range selector chips
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: ChartRange.values.map((range) {
            final isSelected = range == _selectedRange;
            return GestureDetector(
              onTap: () {
                // Reset zoom when changing range
                _transformController.value = Matrix4.identity();
                setState(() {
                  _selectedRange = range;
                  _touchedIndex = null;
                });
              },
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: isSelected
                      ? Colors.blueAccent.withAlpha(40)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isSelected
                        ? Colors.blueAccent
                        : Colors.grey.withAlpha(50),
                  ),
                ),
                child: Text(
                  range.label,
                  style: TextStyle(
                    color: isSelected
                        ? Colors.blueAccent[100]
                        : Colors.grey[500],
                    fontSize: 12,
                    fontWeight:
                        isSelected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

/// A small overview chart that's always visible.
/// When zoomed, shows a viewport rectangle and supports tap-to-navigate.
class _Minimap extends StatelessWidget {
  final List<FlSpot> spots;
  final Color lineColor;
  final double minY;
  final double maxY;
  final TransformationController transformController;

  const _Minimap({
    required this.spots,
    required this.lineColor,
    required this.minY,
    required this.maxY,
    required this.transformController,
  });

  void _onTap(double tapFraction) {
    final matrix = transformController.value;
    final scaleX = matrix.getMaxScaleOnAxis();
    if (scaleX <= 1.05) return; // not zoomed, nothing to navigate

    // Center the viewport on the tapped position
    final viewWidth = 1.0 / scaleX;
    final targetStart = (tapFraction - viewWidth / 2).clamp(0.0, 1.0 - viewWidth);
    final translateX = -targetStart * scaleX;

    // Keep the same horizontal-only scale, just change translation
    final newMatrix = Matrix4.identity()
      ..setEntry(0, 0, scaleX)
      ..setTranslationRaw(translateX, 0, 0);
    transformController.value = newMatrix;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: transformController,
      builder: (context, _) {
        final matrix = transformController.value;
        final scaleX = matrix.getMaxScaleOnAxis();
        final isZoomed = scaleX > 1.05;

        final translateX = matrix.getTranslation().x;
        final viewStart =
            (-translateX / scaleX).clamp(0.0, 1.0 - 1.0 / scaleX);
        final viewWidth = (1.0 / scaleX).clamp(0.0, 1.0);

        return GestureDetector(
          onTapDown: (details) {
            final box = context.findRenderObject() as RenderBox?;
            if (box == null) return;
            final fraction = details.localPosition.dx / box.size.width;
            _onTap(fraction.clamp(0.0, 1.0));
          },
          onHorizontalDragUpdate: (details) {
            final box = context.findRenderObject() as RenderBox?;
            if (box == null) return;
            final fraction = details.localPosition.dx / box.size.width;
            _onTap(fraction.clamp(0.0, 1.0));
          },
          child: SizedBox(
            height: 32,
            child: Stack(
              children: [
                // Mini line chart
                Positioned.fill(
                  child: LineChart(
                    LineChartData(
                      gridData: const FlGridData(show: false),
                      titlesData: const FlTitlesData(show: false),
                      borderData: FlBorderData(
                        show: true,
                        border:
                            Border.all(color: Colors.white.withAlpha(15)),
                      ),
                      minY: minY,
                      maxY: maxY,
                      lineBarsData: [
                        LineChartBarData(
                          spots: spots,
                          isCurved: true,
                          curveSmoothness: 0.2,
                          color: lineColor.withAlpha(80),
                          barWidth: 1,
                          dotData: const FlDotData(show: false),
                        ),
                      ],
                      lineTouchData: const LineTouchData(enabled: false),
                    ),
                  ),
                ),
                // Viewport indicator (only when zoomed)
                if (isZoomed)
                  Positioned.fill(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final left = viewStart * constraints.maxWidth;
                        final width = viewWidth * constraints.maxWidth;
                        return Stack(
                          children: [
                            Positioned(
                              left: left,
                              width: width,
                              top: 0,
                              bottom: 0,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.blueAccent.withAlpha(25),
                                  border: Border.all(
                                    color: Colors.blueAccent.withAlpha(80),
                                    width: 1,
                                  ),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
