import 'package:flutter/material.dart';

/// Shared loading/error scaffold for screens that depend on inventory data.
class InventoryLoading extends StatelessWidget {
  final String title;
  final String? error;
  final VoidCallback? onRetry;

  const InventoryLoading({
    super.key,
    required this.title,
    this.error,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: Center(
        child: error != null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline, size: 48, color: Colors.redAccent[100]),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Text(
                      error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                  ),
                  if (onRetry != null) ...[
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                    ),
                  ],
                ],
              )
            : const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Loading...'),
                ],
              ),
      ),
    );
  }
}
