import 'package:flutter/material.dart';

import 'map_tile_config.dart';

/// The shared attribution for the active tile source, rendered as a
/// `FlutterMap` child. Fed by [MapTileConfig.attribution]; renders nothing when
/// the config carries none.
class MapTileAttribution extends StatelessWidget {
  const MapTileAttribution({
    super.key,
    required this.config,
    this.alignment = Alignment.bottomRight,
  });

  final MapTileConfig config;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    final attribution = config.attribution;
    if (attribution == null) return const SizedBox.shrink();
    return Align(
      alignment: alignment,
      child: IgnorePointer(
        child: Container(
          margin: const EdgeInsets.all(4),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.white70,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            attribution,
            style: const TextStyle(fontSize: 10, color: Colors.black87),
          ),
        ),
      ),
    );
  }
}
