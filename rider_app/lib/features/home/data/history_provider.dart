import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
import '../../../core/api/api_exceptions.dart';
import '../../../core/api/endpoints.dart';
import '../../../core/auth/auth_provider.dart';
import '../model/ride_summary.dart';

class HistoryState {
  final List<RideSummary> rides;
  final int page;
  final int totalPages;
  final bool hasMore;
  final bool isLoading;
  final bool isLoadingMore;
  final String? error;

  const HistoryState({
    this.rides = const [],
    this.page = 0,
    this.totalPages = 0,
    this.hasMore = false,
    this.isLoading = false,
    this.isLoadingMore = false,
    this.error,
  });

  HistoryState copyWith({
    List<RideSummary>? rides,
    int? page,
    int? totalPages,
    bool? hasMore,
    bool? isLoading,
    bool? isLoadingMore,
    String? error,
  }) {
    return HistoryState(
      rides: rides ?? this.rides,
      page: page ?? this.page,
      totalPages: totalPages ?? this.totalPages,
      hasMore: hasMore ?? this.hasMore,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      error: error,
    );
  }
}

class HistoryNotifier extends StateNotifier<HistoryState> {
  static const int perPage = 20;

  final ApiClient _apiClient;

  HistoryNotifier(this._apiClient) : super(const HistoryState());

  Future<void> firstPage() async {
    state = state.copyWith(isLoading: true);
    await _fetch(page: 1, append: false);
  }

  Future<void> loadMore() async {
    if (state.isLoading || state.isLoadingMore || !state.hasMore) return;
    final nextPage = state.page + 1;
    if (nextPage > state.totalPages) return;
    state = state.copyWith(isLoadingMore: true);
    await _fetch(page: nextPage, append: true);
  }

  Future<void> _fetch({required int page, required bool append}) async {
    try {
      final response = await _apiClient.dio.get(
        ApiEndpoints.ridesHistory,
        queryParameters: {'page': page, 'per_page': perPage},
      );
      final data = response.data as Map<String, dynamic>;
      final rides = (data['rides'] as List<dynamic>? ?? [])
          .map((json) => RideSummary.fromJson(json as Map<String, dynamic>))
          .toList();
      final currentPage = (data['page'] as num?)?.toInt() ?? page;
      final totalPages = (data['total_pages'] as num?)?.toInt() ?? 0;
      state = HistoryState(
        rides: append ? [...state.rides, ...rides] : rides,
        page: currentPage,
        totalPages: totalPages,
        hasMore: currentPage < totalPages,
      );
    } on DioException catch (e) {
      state = state.copyWith(
        isLoading: false,
        isLoadingMore: false,
        hasMore: append ? state.hasMore : false,
        error: _mapError(e),
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        isLoadingMore: false,
        hasMore: append ? state.hasMore : false,
        error: e.toString(),
      );
    }
  }

  String _mapError(DioException e) {
    final mapped = e.error;
    final statusCode = e.response?.statusCode ?? 0;
    final message = mapped is ApiException ? mapped.message : _messageFromBody(e);
    return mapStatusCodeToException(statusCode, message).message;
  }

  String _messageFromBody(DioException e) {
    final data = e.response?.data;
    if (data is Map) {
      final error = data['error'];
      if (error is Map && error['message'] != null) {
        return error['message'] as String;
      }
      if (data['message'] != null) return data['message'] as String;
    }
    return 'Failed to load ride history';
  }
}

final historyProvider =
    StateNotifierProvider<HistoryNotifier, HistoryState>((ref) {
  return HistoryNotifier(ref.read(apiClientProvider));
});
