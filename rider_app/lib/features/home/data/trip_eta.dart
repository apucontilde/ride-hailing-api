/// The backend's placeholder ETA, from `internal/service/dispatch.go:276`:
/// the driver→pickup duration falls back to 300 s when the routing engine or
/// the driver location is unavailable. `300` therefore means **unknown**, not
/// "5 minutes", and must never be rendered as a happy path ETA.
const int unknownEtaSeconds = 300;

/// A rider-facing ETA duration, or `null` when the value cannot be trusted.
///
/// Returns `null` for a missing, non-positive, or [unknownEtaSeconds] value —
/// the caller renders an explicit "unknown" state instead of inventing a time.
/// Rounds up so a 30 s leg reads "1 min" rather than "0 min".
String? etaLabel(int? seconds) {
  if (seconds == null || seconds <= 0 || seconds == unknownEtaSeconds) {
    return null;
  }
  return '${(seconds / 60).ceil()} min';
}
