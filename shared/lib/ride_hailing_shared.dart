/// Shared core logic for the ride-hailing rider and driver apps.
///
/// Consumers import `package:ride_hailing_shared/ride_hailing_shared.dart`.
library;

export 'src/api/api_client.dart';
export 'src/api/api_exceptions.dart';
export 'src/auth/auth_storage.dart';
export 'src/auth/app_auth_controller.dart';
export 'src/network/websocket_service.dart';
export 'src/theme/app_theme.dart';
export 'src/utils/validators.dart';
export 'src/utils/location_helper.dart';
export 'src/models/auth_user.dart';
export 'src/models/ride.dart';