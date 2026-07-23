import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/net_error.dart';

/// What a screen shows in place of its content when the load failed.
///
/// Always offer [onRetry] where the screen can reload itself — a dropped
/// connection is nearly always over by the time the rep reads the message,
/// and backing out of the screen just to come back in is the workaround they
/// would otherwise be left with.
class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.error, this.onRetry});

  final Object? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final offline = isOffline(error);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(offline ? Icons.wifi_off_rounded : Icons.error_outline_rounded,
              size: 56, color: Colors.black26),
          const SizedBox(height: 14),
          Text(errorTitle(error),
              textAlign: TextAlign.center,
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(errorDetail(error),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Colors.black54)),
          if (onRetry != null) ...[
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ]),
      ),
    );
  }
}

/// The same message where the failure cost the screen one field rather than
/// all of it — a dropdown that could not load its options, say. Stays inline
/// so the rest of the form is still usable.
class InlineError extends StatelessWidget {
  const InlineError({super.key, required this.error, this.onRetry, this.label});

  final Object? error;
  final VoidCallback? onRetry;

  /// What failed, when the surrounding form does not make it obvious.
  final String? label;

  @override
  Widget build(BuildContext context) {
    final offline = isOffline(error);
    final text = label == null
        ? errorDetail(error)
        : '$label — ${offline ? kNoConnectionBody : errorDetail(error)}';
    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      Icon(offline ? Icons.wifi_off_rounded : Icons.error_outline_rounded,
          size: 16, color: Colors.red.shade400),
      const SizedBox(width: 6),
      Expanded(
        child: Text(text,
            style: TextStyle(fontSize: 12, color: Colors.red.shade400)),
      ),
      if (onRetry != null)
        TextButton(
          onPressed: onRetry,
          style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8)),
          child: const Text('Retry', style: TextStyle(fontSize: 12)),
        ),
    ]);
  }
}

/// Reports an action that did not go through, without taking over the screen.
/// Offline gets the same wording as [ErrorView] so the two never disagree.
void showErrorSnack(BuildContext context, Object? error, {VoidCallback? onRetry}) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(errorLine(error)),
    duration: const Duration(seconds: 5),
    action: onRetry == null
        ? null
        : SnackBarAction(label: 'Retry', onPressed: onRetry),
  ));
}
