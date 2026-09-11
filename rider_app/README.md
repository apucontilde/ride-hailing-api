# Rider App

Flutter frontend for the ride-hailing API. Works on Android and Web.

## Prerequisites

- Flutter SDK 3.x ([install guide](https://docs.flutter.dev/get-started/install))
- The backend API running at `http://localhost:8080`

## Setup

```bash
flutter pub get
```

## Running

### Web

```bash
flutter run -d chrome
```

### Android (emulator)

```bash
# Start an emulator first, or list available devices
flutter devices

# Run on a connected device or emulator
flutter run -d android
```

To run on a physical Android device, enable USB debugging and connect via cable.

## API Configuration

By default the app expects the backend at `http://localhost:8080`.

Override at build time with `--dart-define`:

```bash
flutter run -d chrome --dart-define=API_BASE_URL=http://192.168.1.100:8080
```

Or edit the constant in `lib/config.dart`.
