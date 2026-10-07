import 'package:flutter/material.dart';

import '../model/place.dart';

/// Reorders [stops] in place using the indices `ReorderableListView` reports to
/// [ReorderableListView.onReorderItem].
///
/// `onReorderItem` already adjusts `newIndex` for the item removed at
/// `oldIndex` (Flutter decrements it on a downward move), so the insert index is
/// final and must **not** be adjusted again here. Keeping the mutation in this
/// function (rather than inline in the screen) makes the order semantics
/// testable without driving a drag gesture.
void applyStopReorder(List<Place> stops, int oldIndex, int newIndex) {
  if (oldIndex < 0 ||
      oldIndex >= stops.length ||
      newIndex < 0 ||
      newIndex >= stops.length ||
      oldIndex == newIndex) {
    return;
  }
  final item = stops.removeAt(oldIndex);
  stops.insert(newIndex, item);
}

/// The ordered intermediate-stop editor on Home.
///
/// Order in [stops] **is** the itinerary: the client never sends a `sequence`,
/// and the final destination stays a separate top-level field. The widget only
/// reports intent — the parent owns the list and calls [applyStopReorder].
class StopList extends StatelessWidget {
  const StopList({
    super.key,
    required this.stops,
    required this.onAdd,
    required this.onRemove,
    required this.onReorder,
  });

  final List<Place> stops;
  final VoidCallback onAdd;
  final ValueChanged<int> onRemove;
  final void Function(int oldIndex, int newIndex) onReorder;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (stops.isNotEmpty)
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: stops.length,
            onReorderItem: onReorder,
            itemBuilder: (context, index) {
              final stop = stops[index];
              final label = stop.name.isNotEmpty ? stop.name : stop.address;
              return ListTile(
                key: ObjectKey(stop),
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: ReorderableDragStartListener(
                  index: index,
                  child: const Icon(Icons.drag_handle),
                ),
                title: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Remove stop',
                  onPressed: () => onRemove(index),
                ),
              );
            },
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey<String>('add-stop-button'),
            onPressed: onAdd,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add stop'),
          ),
        ),
      ],
    );
  }
}
