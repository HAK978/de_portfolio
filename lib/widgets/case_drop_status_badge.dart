import 'package:flutter/material.dart';

import '../services/case_pool.dart';

/// Small colored badge that summarizes a container's drop-pool status:
/// green "Active Drop" for cases currently in rotation, gray
/// "Discontinued" for retired ones. Returns `SizedBox.shrink()` for
/// non-applicable containers so callers can drop it into rows
/// unconditionally.
///
/// Use `compact: true` for tight contexts like list rows.
class CaseDropStatusBadge extends StatelessWidget {
  final CaseDropStatus status;
  final bool compact;

  const CaseDropStatusBadge({
    super.key,
    required this.status,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    if (status == CaseDropStatus.notApplicable) {
      return const SizedBox.shrink();
    }

    final (label, color) = switch (status) {
      CaseDropStatus.activeDrop => ('Active Drop', Colors.greenAccent),
      CaseDropStatus.discontinued => ('Discontinued', Colors.grey),
      CaseDropStatus.notApplicable => ('', Colors.transparent),
    };

    final fontSize = compact ? 10.0 : 12.0;
    final padH = compact ? 6.0 : 10.0;
    final padV = compact ? 2.0 : 4.0;

    return Container(
      padding: EdgeInsets.symmetric(horizontal: padH, vertical: padV),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(compact ? 4 : 8),
        border: Border.all(color: color.withAlpha(120)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
