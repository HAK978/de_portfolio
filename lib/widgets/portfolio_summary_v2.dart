import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Value breakdown for a single source (inventory or a storage unit).
class PortfolioSource {
  final String label;
  final IconData icon;
  final double steamValue;
  final double csfloatValue;
  final int itemCount;

  const PortfolioSource({
    required this.label,
    required this.icon,
    required this.steamValue,
    required this.csfloatValue,
    required this.itemCount,
  });
}

/// Expandable total card — collapsed shows total, tap to reveal breakdown.
class PortfolioSummaryV2 extends StatefulWidget {
  final double totalSteamValue;
  final double totalCsfloatValue;
  final int totalItems;
  final List<PortfolioSource> sources;

  const PortfolioSummaryV2({
    super.key,
    required this.totalSteamValue,
    required this.totalCsfloatValue,
    required this.totalItems,
    required this.sources,
  });

  @override
  State<PortfolioSummaryV2> createState() => _PortfolioSummaryV2State();
}

class _PortfolioSummaryV2State extends State<PortfolioSummaryV2> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.currency(symbol: '\$');

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => setState(() => _expanded = !_expanded),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Total row ──
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Total Portfolio',
                          style: TextStyle(color: Colors.grey[400], fontSize: 13),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          fmt.format(widget.totalSteamValue),
                          style: const TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        if (widget.totalCsfloatValue > 0) ...[
                          const SizedBox(height: 2),
                          Text(
                            'CSFloat ${fmt.format(widget.totalCsfloatValue)}',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Colors.blueAccent[100],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  // Expand/collapse chevron
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      Icons.keyboard_arrow_down,
                      color: Colors.grey[500],
                    ),
                  ),
                ],
              ),

              // ── Item count ──
              const SizedBox(height: 8),
              Text(
                '${widget.totalItems} items across ${widget.sources.length} ${widget.sources.length == 1 ? 'source' : 'sources'}',
                style: TextStyle(color: Colors.grey[500], fontSize: 13),
              ),

              // ── Expandable breakdown ──
              AnimatedCrossFade(
                firstChild: const SizedBox.shrink(),
                secondChild: _buildBreakdown(fmt),
                crossFadeState:
                    _expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
                duration: const Duration(milliseconds: 200),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBreakdown(NumberFormat fmt) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 14, bottom: 10),
          child: Divider(color: Colors.grey[800], height: 1),
        ),
        // Column headers
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              const Expanded(child: SizedBox()),
              SizedBox(
                width: 90,
                child: Text(
                  'Steam',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    color: Colors.grey[500],
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              SizedBox(
                width: 90,
                child: Text(
                  'CSFloat',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    color: Colors.blueAccent[100]?.withValues(alpha: 0.7),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        ...widget.sources.map((s) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Icon(s.icon, size: 16, color: Colors.grey[500]),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.label,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          '${s.itemCount} items',
                          style: TextStyle(color: Colors.grey[600], fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 90,
                    child: Text(
                      fmt.format(s.steamValue),
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 90,
                    child: Text(
                      s.csfloatValue > 0 ? fmt.format(s.csfloatValue) : '—',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: 13,
                        color: s.csfloatValue > 0
                            ? Colors.blueAccent[100]
                            : Colors.grey[700],
                      ),
                    ),
                  ),
                ],
              ),
            )),
      ],
    );
  }
}
