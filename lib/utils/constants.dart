import 'dart:io';

/// SignalR notification type: the server logged this user out (key rotation,
/// KDF change, password change, "deauthorize sessions"). Payload may carry a
/// `Reason` (Bitwarden: 0 = KDF change, 1 = key rotation).
const kLogOutNotificationType = 11;

/// LogOut `Reason` 0 (`PushNotificationLogOutReason.KdfChange`): bitwarden.com
/// sends it with `NoLogoutOnKdfChange` on, where the security stamp is *not*
/// refreshed and the user key is unchanged. The official clients ignore it
/// (default-server-notifications.service.ts); so does this app. A session
/// that really died is still caught by the refresh path (F11).
const kLogOutReasonKdfChange = 0;

/// SignalR notification type for new auth request.
const kAuthRequestNotificationType = 15;

/// SignalR notification type for auth request response (approved elsewhere).
const kAuthRequestResponseNotificationType = 16;

/// How long a "Login with device" request can still be acted upon.
///
/// Vaultwarden only lets the requester consume an approval within 5 minutes
/// of creation (bitwarden.com: 15); the official Android app treats requests
/// older than 5 minutes as not actionable. We use 5 minutes for all servers.
const kAuthRequestActionableWindow = Duration(minutes: 5);

/// Polling interval for auth requests when WebSocket is unavailable.
const kPollIntervalSeconds = 15;

/// SignalR keep-alive ping interval — half the server's default 30 s client
/// timeout (ASP.NET Core SignalR on bitwarden.com).
const kHubPingInterval = Duration(seconds: 15);

/// `Bitwarden-Client-Version` sent on every request.
///
/// bitwarden.com rejects password logins without it (`version_header_missing`,
/// since 2026-02-23) and requires ≥ 2025.11.0 for V2-encryption accounts.
/// Format is the official clients' YYYY.M.P — never the app's pubspec version.
/// Bump it over time together with the official client releases.
const kBitwardenClientVersion = '2026.9.0';

/// `Bitwarden-Client-Name` sent on every request (same as the official
/// mobile apps).
const kBitwardenClientName = 'mobile';

/// Bitwarden `DeviceType` of this device: 1 = iOS, 0 = Android.
///
/// Used for the `Device-Type` header and the `deviceType` token-form field so
/// both always agree.
String bitwardenDeviceType() => Platform.isIOS ? '1' : '0';
