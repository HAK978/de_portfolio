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

/// Interactive line chart with manual zoom/pan and a minimap navigator.
///
/// Zoom/pan is handled via GestureDetector controlling a [_viewStart, _viewEnd]
/// window (0–1 fractions of the full daily data timeline). The minimap always
/// shows all data with a viewport rectangle that tracks the visible window.
class PriceChart extends StatefulWidget {
  final List<PriceHistoryPoint> data;

  const PriceChart({super.key, required this.data});

  @override
  State<PriceChart> createState() => _PriceChartState();
}

class _PriceChartState extends State<PriceChart> {
  /// Switch to hourly granularity once a visible day has at least this
  /// many hourly samples — daily aggregation feels choppy below this
  /// density.
  static const _hourlyDailyThreshold = 10;

  /// Y-axis reserved width on the left edge of fl_chart's
  /// LineChart — used to translate tap positions into data indices.
  /// Must match the SideTitlesData reservedSize below.
  static const _yAxisReservedWidth = 52.0;

  ChartRange _selectedRange = ChartRange.month;
  int? _touchedIndex;

  /// Daily-aggregated version of the full dataset.
  late List<PriceHistoryPoint> _dailyData;

  /// Visible window as fractions of the total daily data timeline [0.0, 1.0].
  double _viewStart = 0.0;
  double _viewEnd = 1.0;

  // Gesture tracking
  double _baseViewWidth = 1.0;
  double _baseViewCenter = 0.5;
  Offset? _gestureStartFocal;
  bool _gestureDidMove = false;

  Offset? _pointerDownPos;
  final _chartKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _dailyData = _aggregateDaily(widget.data);
    _applyRange(_selectedRange);
  }

  @override
  void didUpdateWidget(PriceChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data) {
      _dailyData = _aggregateDaily(widget.data);
      _applyRange(_selectedRange);
    }
  }

  /// Set the visible window to show the most recent N days for a range chip.
  void _applyRange(ChartRange range) {
    if (range == ChartRange.all || range.days == 0 || _dailyData.length < 2) {
      _viewStart = 0.0;
      _viewEnd = 1.0;
      return;
    }
    final allStart = _dailyData.first.date;
    final allEnd = _dailyData.last.date;
    final totalHours = allEnd.difference(allStart).inHours.toDouble();
    if (totalHours <= 0) {
      _viewStart = 0.0;
      _viewEnd = 1.0;
      return;
    }
    final rangeHours = range.days * 24.0;
    final width = (rangeHours / totalHours).clamp(0.0, 1.0);
    _viewEnd = 1.0;
    _viewStart = (1.0 - width).clamp(0.0, 1.0);
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

  /// Get the data visible in the current window, with hourly/daily auto-switch.
  List<PriceHistoryPoint> _getVisibleData() {
    if (_dailyData.isEmpty) return [];
    if (_dailyData.length < 2) return _dailyData;

    final allStart = _dailyData.first.date;
    final allEnd = _dailyData.last.date;
    final totalSpan = allEnd.difference(allStart);
    final visStart = allStart.add(totalSpan * _viewStart);
    final visEnd = allStart.add(totalSpan * _viewEnd);
    final visDays = visEnd.difference(visStart).inDays.clamp(1, 9999);

    // For short visible spans with high trade volume, use hourly data
    if (visDays <= 30) {
      final hourly = widget.data
          .where(
              (p) => !p.date.isBefore(visStart) && !p.date.isAfter(visEnd))
          .toList();
      if (hourly.isNotEmpty &&
          hourly.length / visDays >= _hourlyDailyThreshold) {
        return hourly;
      }
    }

    return _dailyData
        .where(
            (p) => !p.date.isBefore(visStart) && !p.date.isAfter(visEnd))
        .toList();
  }

  double get _chartPixelWidth {
    final box = _chartKey.currentContext?.findRenderObject() as RenderBox?;
    return box?.size.width ?? 300;
  }

  /// Minimum zoom window: allow viewing down to ~6 hours of data.
  double get _minWindow {
    if (_dailyData.length < 2) return 0.1;
    final totalHours =
        _dailyData.last.date.difference(_dailyData.first.date).inHours;
    if (totalHours <= 0) return 0.1;
    return (6.0 / totalHours).clamp(0.001, 0.5);
  }

  // --- Gesture handlers for main chart zoom/pan ---

  void _onGestureStart(ScaleStartDetails details) {
    _baseViewWidth = _viewEnd - _viewStart;
    _baseViewCenter = (_viewStart + _viewEnd) / 2;
    _gestureStartFocal = details.localFocalPoint;
    _gestureDidMove = false;
  }

  void _onGestureUpdate(ScaleUpdateDetails details) {
    final moved = _gestureStartFocal != null &&
        (details.localFocalPoint - _gestureStartFocal!).distance > 8;
    final zooming =
        details.pointerCount >= 2 && (details.scale - 1.0).abs() > 0.01;

    if (moved || zooming) _gestureDidMove = true;
    if (!_gestureDidMove) return;

    setState(() {
      if (details.pointerCount >= 2) {
        final newWidth =
            (_baseViewWidth / details.scale).clamp(_minWindow, 1.0);
        _viewStart =
            (_baseViewCenter - newWidth / 2).clamp(0.0, 1.0 - newWidth);
        _viewEnd = _viewStart + newWidth;

      } else {
        // Single finger: pan
        final w = _viewEnd - _viewStart;
        final cw = _chartPixelWidth;
        if (cw > 0) {
          final panFrac = -details.focalPointDelta.dx / cw * w;
          final newStart = (_viewStart + panFrac).clamp(0.0, 1.0 - w);
          _viewStart = newStart;
          _viewEnd = newStart + w;
        }
      }
      _touchedIndex = null;
      _updateSelectedRange();
    });
  }

  void _onGestureEnd(ScaleEndDetails details) {
    // Tap detection is handled by the Listener wrapper
  }

  /// Auto-switch the selected range chip based on how many days are visible.
  void _updateSelectedRange() {
    if (_dailyData.length < 2) return;
    // Viewing almost everything → All
    if ((_viewEnd - _viewStart) > 0.95) {
      _selectedRange = ChartRange.all;
      return;
    }
    final totalDays =
        _dailyData.last.date.difference(_dailyData.first.date).inDays;
    if (totalDays <= 0) return;
    final visDays = ((_viewEnd - _viewStart) * totalDays).round();

    if (visDays <= 10) {
      _selectedRange = ChartRange.week;
    } else if (visDays <= 45) {
      _selectedRange = ChartRange.month;
    } else if (visDays <= 120) {
      _selectedRange = ChartRange.threeMonths;
    } else if (visDays <= 240) {
      _selectedRange = ChartRange.sixMonths;
    } else {
      _selectedRange = ChartRange.year;
    }
  }

  void _handleChartTap(Offset localPosition) {
    final data = _getVisibleData();
    if (data.isEmpty) return;
    final cw = _chartPixelWidth;
    final dataAreaWidth = cw - _yAxisReservedWidth;
    final dataX = localPosition.dx - _yAxisReservedWidth;
    if (dataX < 0 || dataX > dataAreaWidth || dataAreaWidth <= 0) return;
    final index = (dataX / dataAreaWidth * (data.length - 1))
        .round()
        .clamp(0, data.length - 1);
    setState(() => _touchedIndex = index);
  }

  // --- Minimap drag ---

  void _onMinimapDrag(double fraction) {
    setState(() {
      final width = _viewEnd - _viewStart;
      _viewStart = (fraction - width / 2).clamp(0.0, 1.0 - width);
      _viewEnd = _viewStart + width;
      _touchedIndex = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final data = _getVisibleData();

    // Minimap: always show ALL daily data
    final minimapSpots = <FlSpot>[];
    for (int i = 0; i < _dailyData.length; i++) {
      minimapSpots.add(FlSpot(i.toDouble(), _dailyData[i].price));
    }
    final allPrices = _dailyData.map((p) => p.price).toList();
    final allMinPrice =
        allPrices.isEmpty ? 0.0 : allPrices.reduce(math.min);
    final allMaxPrice =
        allPrices.isEmpty ? 1.0 : allPrices.reduce(math.max);
    final allRange = allMaxPrice - allMinPrice;
    final allPadding = allRange > 0 ? allRange * 0.1 : allMaxPrice * 0.1;

    if (data.isEmpty) {
      return Column(
        children: [
          SizedBox(
            height: 200,
            child: Center(
              child: Text('No price data for this period',
                  style: TextStyle(color: Colors.grey[600])),
            ),
          ),
          const SizedBox(height: 4),
          if (minimapSpots.isNotEmpty)
            _Minimap(
              spots: minimapSpots,
              lineColor: Colors.grey,
              minY: (allMinPrice - allPadding).clamp(0, double.infinity),
              maxY: allMaxPrice + allPadding,
              viewStart: _viewStart,
              viewEnd: _viewEnd,
              onDrag: _onMinimapDrag,
            ),
          const SizedBox(height: 8),
          _buildRangeChips(),
        ],
      );
    }

    final spots = <FlSpot>[];
    for (int i = 0; i < data.length; i++) {
      spots.add(FlSpot(i.toDouble(), data[i].price));
    }

    final prices = data.map((p) => p.price).toList();
    final minPrice = prices.reduce(math.min);
    final maxPrice = prices.reduce(math.max);
    final priceRange = maxPrice - minPrice;
    final padding = priceRange > 0 ? priceRange * 0.1 : maxPrice * 0.1;

    final firstPrice = data.first.price;
    final lastPrice = data.last.price;
    final priceChange = lastPrice - firstPrice;
    final percentChange =
        firstPrice > 0 ? (priceChange / firstPrice) * 100 : 0.0;
    final isPositive = priceChange >= 0;
    final lineColor = isPositive ? Colors.greenAccent : Colors.redAccent;

    final totalDays = _dailyData.length < 2
        ? 1
        : _dailyData.last.date
            .difference(_dailyData.first.date)
            .inDays
            .clamp(1, 99999);
    final visDays = ((_viewEnd - _viewStart) * totalDays).clamp(1, 99999);
    final isHourly = data.length > visDays * 1.5;

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

        // Main chart with manual zoom/pan + Listener for tap detection
        Listener(
          onPointerDown: (e) {
            _pointerDownPos = e.localPosition;
            _gestureDidMove = false;
          },
          onPointerUp: (e) {
            if (!_gestureDidMove && _pointerDownPos != null) {
              _handleChartTap(_pointerDownPos!);
            }
            _pointerDownPos = null;
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onScaleStart: _onGestureStart,
            onScaleUpdate: _onGestureUpdate,
            onScaleEnd: _onGestureEnd,
            child: SizedBox(
            key: _chartKey,
            height: 200,
            child: IgnorePointer(
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
                      reservedSize: _yAxisReservedWidth,
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
                        if (isHourly && visDays <= 7) {
                          format = DateFormat('d/M HH:mm');
                        } else if (visDays <= 90) {
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
                  enabled: false,
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
            ),
            ),
          ),
        ),
        ),
        const SizedBox(height: 4),

        // Minimap — always shows ALL data, viewport tracks visible window
        _Minimap(
          spots: minimapSpots,
          lineColor: lineColor,
          minY: (allMinPrice - allPadding).clamp(0, double.infinity),
          maxY: allMaxPrice + allPadding,
          viewStart: _viewStart,
          viewEnd: _viewEnd,
          onDrag: _onMinimapDrag,
        ),
        const SizedBox(height: 8),

        // Range selector chips
        _buildRangeChips(),
      ],
    );
  }

  Widget _buildRangeChips() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: ChartRange.values.map((range) {
        final isSelected = range == _selectedRange;
        return GestureDetector(
          onTap: () {
            setState(() {
              _selectedRange = range;
              _applyRange(range);
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
    );
  }
}

/// Small overview chart showing ALL data with a draggable viewport indicator.
class _Minimap extends StatelessWidget {
  final List<FlSpot> spots;
  final Color lineColor;
  final double minY;
  final double maxY;
  final double viewStart;
  final double viewEnd;
  final ValueChanged<double>? onDrag;

  const _Minimap({
    required this.spots,
    required this.lineColor,
    required this.minY,
    required this.maxY,
    required this.viewStart,
    required this.viewEnd,
    this.onDrag,
  });

  @override
  Widget build(BuildContext context) {
    final showViewport = (viewEnd - viewStart) < 0.99;

    return GestureDetector(
      onTapDown: (details) {
        if (onDrag == null) return;
        final box = context.findRenderObject() as RenderBox?;
        if (box == null) return;
        onDrag!(
            (details.localPosition.dx / box.size.width).clamp(0.0, 1.0));
      },
      onHorizontalDragUpdate: (details) {
        if (onDrag == null) return;
        final box = context.findRenderObject() as RenderBox?;
        if (box == null) return;
        onDrag!(
            (details.localPosition.dx / box.size.width).clamp(0.0, 1.0));
      },
      child: SizedBox(
        height: 32,
        child: Stack(
          children: [
            Positioned.fill(
              child: LineChart(
                LineChartData(
                  gridData: const FlGridData(show: false),
                  titlesData: const FlTitlesData(show: false),
                  borderData: FlBorderData(
                    show: true,
                    border: Border.all(color: Colors.white.withAlpha(15)),
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
            if (showViewport)
              Positioned.fill(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final left = viewStart * constraints.maxWidth;
                    final width =
                        ((viewEnd - viewStart) * constraints.maxWidth)
                            .clamp(4.0, constraints.maxWidth);
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
  }
}
