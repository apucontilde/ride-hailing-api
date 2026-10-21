import 'package:flutter/material.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

/// Scrollable sheet content with an optional pinned action footer.
///
/// Bottom padding clears the bottom safe area when there is no footer; with a
/// footer the safe area is owned by the footer, so it never scrolls away.
class RiderSheetScrollBody extends StatelessWidget {
  const RiderSheetScrollBody({
    super.key,
    required this.child,
    this.footer,
    this.scrollController,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
  });

  final Widget child;
  final Widget? footer;
  final ScrollController? scrollController;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final footer = this.footer;
    final resolvedPadding = footer == null
        ? padding.add(
            EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
          )
        : padding;
    final body = SingleChildScrollView(
      key: const ValueKey<String>('rider-sheet-scroll'),
      controller: scrollController,
      padding: resolvedPadding,
      child: child,
    );
    if (footer == null) return body;
    // Shrink-wrap to the content up to the parent's max height: a short list
    // keeps the modal content-height instead of filling the whole constraint,
    // while a long list scrolls in the `Flexible` body with the action pinned.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(fit: FlexFit.loose, child: body),
        SafeArea(top: false, child: footer),
      ],
    );
  }
}

/// Movable + scrollable non-modal rider sheet.
///
/// A content-fit [DraggableScrollableSheet] with three positions:
///
/// - min: the handle-only floor ([_minSize]);
/// - opening: the measured content fit clamped to `[min, maxChildSize]`,
///   applied once with `jumpTo` and exposed as a snap point;
/// - max: `maxChildSize`, so the sheet can always expand to full screen.
///
/// Content taller than the viewport scrolls in the body instead of growing the
/// sheet. [sheetKey] identifies the rendered [AppBottomSheet] so a screen can
/// read the sheet's real height (the active trip uses it for route-fit
/// padding).
class RiderDraggableSheet extends StatefulWidget {
  const RiderDraggableSheet({
    super.key,
    required this.child,
    this.footer,
    this.controller,
    this.sheetKey,
    this.initialChildSize = 0.4,
    this.maxChildSize = 1.0,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
  });

  final Widget child;
  final Widget? footer;
  final DraggableScrollableController? controller;
  final Key? sheetKey;
  final double initialChildSize;
  final double maxChildSize;
  final EdgeInsetsGeometry padding;

  @override
  State<RiderDraggableSheet> createState() => _RiderDraggableSheetState();
}

class _RiderDraggableSheetState extends State<RiderDraggableSheet> {
  /// The handle-only minimum: the same 64 px handle block Home uses, clamped to
  /// a sane floor on very tall surfaces.
  static double _minSize(double availableHeight) {
    if (availableHeight <= 0) return 0.06;
    const handlePx = 64.0;
    return (handlePx / availableHeight).clamp(0.06, 0.5);
  }

  final GlobalKey _contentKey = GlobalKey();
  final GlobalKey _footerKey = GlobalKey();

  DraggableScrollableController? _internalController;

  /// The measured max ceiling (always `maxChildSize`). `null` until the first
  /// post-frame measurement.
  double? _measuredMax;

  /// Stable `snapSizes` identity: rebuilding with a fresh list would make
  /// `DraggableScrollableSheet.didUpdateWidget` re-run its snap on every build.
  List<double>? _snapSizes;

  /// The last measured footer height. At the min snap the footer is hidden (so
  /// it cannot overflow), but the measurement still needs its real height.
  double _footerHeight = 0;

  /// Whether the first layout has been measured. Later measurements may only
  /// raise the max; they never yank the sheet.
  bool _measured = false;

  DraggableScrollableController get _controller =>
      widget.controller ??
      (_internalController ??= DraggableScrollableController());

  /// The footer is only shown once the sheet is at least as tall as the footer
  /// itself. At (or near) the handle-only min there is no room for it, and
  /// rendering it there overflows the sheet.
  bool _footerVisible(double availableHeight) {
    if (!_controller.isAttached) return true;
    return _controller.size * availableHeight >= _footerHeight;
  }

  @override
  void dispose() {
    _internalController?.dispose();
    super.dispose();
  }

  EdgeInsetsGeometry _scrollPadding(BuildContext context) {
    if (widget.footer != null) return widget.padding;
    return widget.padding.add(
      EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
    );
  }

  void _scheduleMeasure(double availableHeight) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || availableHeight <= 0) return;
      final contentContext = _contentKey.currentContext;
      final contentBox = contentContext?.findRenderObject() as RenderBox?;
      if (contentBox == null || !contentBox.hasSize || contentContext == null) {
        return;
      }
      final footerBox =
          _footerKey.currentContext?.findRenderObject() as RenderBox?;
      final measuredFooter = footerBox != null && footerBox.hasSize
          ? footerBox.size.height
          : 0.0;
      if (measuredFooter > 0) _footerHeight = measuredFooter;
      final footerHeight = measuredFooter > 0 ? measuredFooter : _footerHeight;
      final safeBottom = widget.footer == null
          ? MediaQuery.paddingOf(contentContext).bottom
          : 0.0;
      final totalHeight =
          contentBox.size.height +
          footerHeight +
          _scrollPadding(
            contentContext,
          ).resolve(Directionality.of(contentContext)).vertical +
          safeBottom;
      final rawFit = totalHeight / availableHeight;
      final minSize = _minSize(availableHeight);
      // The max is always the sheet's ceiling, so the opening (measured content
      // fit) stays a distinct middle snap and the user can expand to full
      // screen instead of the snap list collapsing to `[max]`.
      final measuredMax = widget.maxChildSize;
      final opening = rawFit.clamp(minSize, measuredMax).toDouble();

      if (!_measured) {
        setState(() {
          _measured = true;
          _measuredMax = measuredMax;
          _snapSizes = <double>[opening];
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_controller.isAttached) return;
          _controller.jumpTo(opening);
        });
      } else if (measuredMax > (_measuredMax ?? 0) + 0.001) {
        // Content grew: only raise the max, never move the current sheet.
        setState(() => _measuredMax = measuredMax);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final availableHeight = MediaQuery.sizeOf(context).height;
    final minSize = _minSize(availableHeight);
    // Keep the reported `initialChildSize` stable: `DraggableScrollableSheet`
    // resets its current size to it on every widget update until the first
    // drag, and notifying the controller mid-build is illegal. The measured
    // content fit is applied with `jumpTo` once after the first layout.
    final initialSize = widget.initialChildSize <= widget.maxChildSize
        ? widget.initialChildSize
        : widget.maxChildSize;
    final rawMax = _measuredMax ?? widget.maxChildSize;
    final maxSize = (rawMax < initialSize ? initialSize : rawMax)
        .clamp(minSize, widget.maxChildSize)
        .toDouble();
    _scheduleMeasure(availableHeight);

    final footer = widget.footer;
    final scrollPadding = _scrollPadding(context);

    return DraggableScrollableSheet(
      controller: _controller,
      snap: true,
      snapAnimationDuration: AppMotion.medium,
      initialChildSize: initialSize,
      minChildSize: minSize,
      maxChildSize: maxSize,
      snapSizes: _snapSizes,
      builder: (context, scrollController) {
        return AppBottomSheet(
          key: widget.sheetKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  key: const ValueKey<String>('rider-sheet-scroll'),
                  controller: scrollController,
                  padding: scrollPadding,
                  child: Column(
                    key: _contentKey,
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [widget.child],
                  ),
                ),
              ),
              if (footer != null)
                AnimatedBuilder(
                  animation: _controller,
                  builder: (context, child) {
                    if (!_footerVisible(availableHeight)) {
                      return const SizedBox.shrink();
                    }
                    return SafeArea(key: _footerKey, top: false, child: footer);
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}
