import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../data/home_provider.dart';
import '../model/place.dart';

class LocationSearchScreen extends ConsumerStatefulWidget {
  final String hint;
  final double? lat;
  final double? lng;

  const LocationSearchScreen({
    super.key,
    this.hint = 'Search destinations...',
    this.lat,
    this.lng,
  });

  @override
  ConsumerState<LocationSearchScreen> createState() => _LocationSearchScreenState();
}

class _LocationSearchScreenState extends ConsumerState<LocationSearchScreen> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lat = widget.lat, lng = widget.lng;
    final placesAsync = (lat == null || lng == null)
        ? const AsyncValue<List<Place>>.data(<Place>[])
        : ref.watch(placeSearchProvider(
            PlaceSearchArgs(query: _query, lat: lat, lng: lng)));

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _searchController,
          autofocus: true,
          decoration: InputDecoration(
            hintText: widget.hint,
            border: InputBorder.none,
          ),
          onChanged: (value) {
            setState(() => _query = value);
          },
        ),
      ),
      body: (lat == null || lng == null)
          ? const Center(child: Text('Enable location to search nearby'))
          : placesAsync.when(
              data: (places) => ListView.separated(
                itemCount: places.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final place = places[index];
                  return _buildPlaceTile(place);
                },
              ),
              loading: () => _query.isNotEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : const Center(child: Text('Start typing to search')),
              error: (e, _) => Center(child: Text('Error: $e')),
            ),
    );
  }

  Widget _buildPlaceTile(Place place) {
    return ListTile(
      leading: const Icon(Icons.location_on_outlined, color: Colors.grey),
      title: Text(place.name),
      subtitle: Text(place.address, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () => context.pop(place),
    );
  }
}
