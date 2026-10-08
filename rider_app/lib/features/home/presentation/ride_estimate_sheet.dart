import 'package:flutter/material.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import '../model/ride_estimate.dart';

class RideEstimateSheet extends StatefulWidget {
  final List<RideEstimate> estimates;
  final double pickupLat;
  final double pickupLng;
  final double dropoffLat;
  final double dropoffLng;

  const RideEstimateSheet({
    super.key,
    required this.estimates,
    required this.pickupLat,
    required this.pickupLng,
    required this.dropoffLat,
    required this.dropoffLng,
  });

  @override
  State<RideEstimateSheet> createState() => _RideEstimateSheetState();
}

class _RideEstimateSheetState extends State<RideEstimateSheet> {
  String? _selectedType;

  @override
  void initState() {
    super.initState();
    if (widget.estimates.isNotEmpty) {
      _selectedType = widget.estimates.first.vehicleType;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.sm,
          ),
          child: AppSectionHeader(
            title: 'Choose a ride',
            trailing: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
          ),
        ),
        ...widget.estimates.map(_buildOption),
        Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: AppButton(
            label: 'Confirm Ride',
            onPressed: _selectedType != null
                ? () => Navigator.of(context).pop(_selectedType)
                : null,
          ),
        ),
      ],
    );
  }

  Widget _buildOption(RideEstimate estimate) {
    final selected = _selectedType == estimate.vehicleType;
    return InkWell(
      onTap: () => setState(() => _selectedType = estimate.vehicleType),
      child: Container(
        margin: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.xs,
        ),
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary.withValues(alpha: 0.1)
              : AppColors.surfaceLow,
          borderRadius: BorderRadius.circular(AppRadii.md),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.outline,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.directions_car,
                  size: 40,
                  color: selected ? AppColors.primary : AppColors.muted,
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        estimate.displayName,
                        style: AppTextStyles.subtitle,
                      ),
                      Text(
                        '${estimate.capacity} passengers',
                        style: AppTextStyles.label.copyWith(
                          color: AppColors.muted,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                      if (estimate.isEstimate)
                        Text(
                          'Estimated fare — not fully road-routed',
                          style: AppTextStyles.caption.copyWith(
                            color: AppColors.warningForeground,
                          ),
                        ),
                    ],
                  ),
                ),
                Text(estimate.formattedTotal, style: AppTextStyles.fare),
              ],
            ),
            if (selected) ...[
              const Divider(height: 20),
              _breakdown(estimate),
            ],
          ],
        ),
      ),
    );
  }

  Widget _breakdown(RideEstimate estimate) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _fareRow('Base fare', estimate.formattedBaseFare),
        _fareRow(
          'Distance fare',
          estimate.formattedDistanceFare,
          note: estimate.hasGradeUplift
              ? 'climb +${(estimate.gradeUpliftPct * 100).toStringAsFixed(1)}%'
              : null,
        ),
        _fareRow('Time fare', estimate.formattedTimeFare),
        _fareRow(
          'Conditions multiplier',
          '×${estimate.surgeMultiplier.toStringAsFixed(2)}',
          note: estimate.demandMultiplier != 1.0 ||
                  estimate.supplyMultiplier != 1.0
              ? 'demand ${estimate.demandMultiplier.toStringAsFixed(2)} '
                  '× supply ${estimate.supplyMultiplier.toStringAsFixed(2)}'
              : null,
        ),
        if (estimate.hasMultipleLegs) ...[
          const Divider(height: 20),
          Text(
            'Trip legs',
            style: AppTextStyles.caption.copyWith(
              fontWeight: FontWeight.w600,
              color: AppColors.mutedStrong,
            ),
          ),
          for (var i = 0; i < estimate.legs.length; i++)
            _fareRow('Leg ${i + 1}', _formatLeg(estimate.legs[i])),
        ],
        const Divider(height: 20),
        _fareRow('Total', estimate.formattedTotal, emphasise: true),
      ],
    );
  }

  /// Informational per-leg distance/duration only. The API's per-leg *fares*
  /// exclude the once-per-trip base and multiplier, so rendering them as money
  /// would invite the rider to sum them; the total stays authoritative.
  String _formatLeg(RideEstimateLeg leg) {
    final km = (leg.distanceM / 1000).toStringAsFixed(1);
    final minutes = (leg.durationS / 60).round();
    return '$km km · ~$minutes min';
  }

  Widget _fareRow(String label, String value,
      {String? note, bool emphasise = false}) {
    final style = emphasise
        ? AppTextStyles.fare.copyWith(fontSize: 15)
        : AppTextStyles.label.copyWith(
            fontWeight: FontWeight.w400,
            color: AppColors.mutedStrong,
          );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: style),
                if (note != null)
                  Text(
                    note,
                    style: AppTextStyles.caption.copyWith(
                      fontSize: 11,
                      color: AppColors.muted,
                    ),
                  ),
              ],
            ),
          ),
          Text(value, style: style),
        ],
      ),
    );
  }
}
