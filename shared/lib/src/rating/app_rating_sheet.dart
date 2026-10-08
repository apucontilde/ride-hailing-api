import 'package:flutter/material.dart';

import '../components/app_bottom_sheet.dart';
import '../components/app_button.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// The one rating form both apps render.
///
/// Presentation only: no Riverpod, no Dio, no app providers. The owning app
/// keeps its endpoint, its `RatingStatus` gate and its double-submit guard; this
/// widget only collects a 1–5 score plus an optional comment and reports intent
/// through [onSubmit]. Whether the prompt is shown at all is the app's decision.
///
/// The submitted star keys preserve both suites at once: the `IconButton` is
/// keyed `rating-star-$value` (the rider) and the icon it wraps is keyed
/// `rate-star-$value` (the driver). Star colors are locked: unselected grey,
/// selected amber.
class AppRatingSheet extends StatefulWidget {
  const AppRatingSheet({
    super.key,
    required this.title,
    this.subtitle,
    this.allowComment = false,
    this.maxCommentLength = 280,
    this.submitLabel = 'Submit rating',
    this.skipLabel = 'Not now',
    this.busy = false,
    this.errorText,
    this.initialScore = 0,
    required this.onSubmit,
    this.onSkip,
  });

  final String title;
  final String? subtitle;
  final bool allowComment;
  final int maxCommentLength;
  final String submitLabel;
  final String skipLabel;

  /// Disables the controls and swaps the submit label for a spinner.
  final bool busy;

  /// Inline failure line shown above the submit button.
  final String? errorText;

  /// The score the sheet opens on; `0` is "nothing picked yet".
  final int initialScore;

  /// Reports a valid 1–5 [score] and the current comment text.
  final void Function(int score, String comment) onSubmit;

  /// The dismiss action; `null` disables skip while [busy].
  final VoidCallback? onSkip;

  @override
  State<AppRatingSheet> createState() => _AppRatingSheetState();
}

class _AppRatingSheetState extends State<AppRatingSheet> {
  late int _score = widget.initialScore;
  final TextEditingController _comment = TextEditingController();

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  /// The server range-checks 1..5 and an in-flight submit must not be repeated,
  /// so an unsubmitted or busy sheet is simply not submittable.
  bool get _canSubmit => _score >= 1 && _score <= 5 && !widget.busy;

  void _submit() {
    if (!_canSubmit) return;
    widget.onSubmit(_score, _comment.text);
  }

  @override
  Widget build(BuildContext context) {
    return AppBottomSheet(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AppSheetHandle(),
          const SizedBox(height: AppSpacing.lg),
          Text(
            widget.title,
            textAlign: TextAlign.center,
            style: AppTextStyles.title,
          ),
          if (widget.subtitle != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              widget.subtitle!,
              textAlign: TextAlign.center,
              style: AppTextStyles.body.copyWith(color: AppColors.muted),
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var star = 1; star <= 5; star++)
                IconButton(
                  key: ValueKey<String>('rating-star-$star'),
                  tooltip: '$star star${star == 1 ? '' : 's'}',
                  onPressed: widget.busy
                      ? null
                      : () => setState(() => _score = star),
                  icon: KeyedSubtree(
                    key: Key('rate-star-$star'),
                    child: Icon(
                      star <= _score ? Icons.star : Icons.star_border,
                      size: 36,
                      color: star <= _score
                          ? AppColors.warning
                          : AppColors.muted,
                    ),
                  ),
                ),
            ],
          ),
          if (widget.allowComment) ...[
            const SizedBox(height: AppSpacing.sm),
            TextField(
              key: const Key('rate-comment'),
              controller: _comment,
              enabled: !widget.busy,
              maxLength: widget.maxCommentLength,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Comment (optional)',
                border: OutlineInputBorder(),
              ),
            ),
          ],
          if (widget.errorText != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              widget.errorText!,
              key: const Key('rate-error'),
              textAlign: TextAlign.center,
              style: AppTextStyles.body.copyWith(color: AppColors.danger),
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          AppButton(
            key: const Key('rate-submit'),
            label: widget.submitLabel,
            expand: true,
            isLoading: widget.busy,
            onPressed: _canSubmit ? _submit : null,
          ),
          if (widget.onSkip != null)
            TextButton(
              key: const Key('rate-skip'),
              onPressed: widget.busy ? null : widget.onSkip,
              child: Text(widget.skipLabel),
            ),
        ],
      ),
    );
  }
}

/// Opens [AppRatingSheet] as a modal bottom sheet.
///
/// The presentation wrapper both apps share: scroll-controlled so the sheet can
/// grow for the comment/keyboard, with the content lifted above the keyboard by
/// its inset. The builder supplies the (possibly app-reactive) sheet body.
Future<T?> showAppRatingSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    elevation: 0,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
      ),
      child: builder(sheetContext),
    ),
  );
}
