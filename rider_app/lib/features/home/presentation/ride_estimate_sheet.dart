import 'package:flutter/material.dart';
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
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Text(
                'Choose a ride',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
        ...widget.estimates.map(_buildOption),
        Padding(
          padding: const EdgeInsets.all(16),
          child: ElevatedButton(
            onPressed: _selectedType != null
                ? () => Navigator.of(context).pop(_selectedType)
                : null,
            child: const Text('Confirm Ride'),
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
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected ? Colors.blue.withValues(alpha: 0.1) : Colors.grey[50],
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? Colors.blue : Colors.grey[300]!,
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(Icons.directions_car, size: 40, color: selected ? Colors.blue : Colors.grey),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    estimate.displayName,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                  ),
                  Text(
                    '${estimate.capacity} passengers',
                    style: TextStyle(color: Colors.grey[600], fontSize: 13),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  estimate.formattedBaseFare,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
