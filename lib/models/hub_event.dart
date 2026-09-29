import '../utils/constants.dart';
import 'json_util.dart';

/// One `ReceiveMessage` notification from the SignalR hub:
/// `{ContextId, Type, Payload}`.
class HubEvent {
  const HubEvent({
    required this.type,
    this.contextId,
    this.payload = const {},
  });

  /// Bitwarden `PushType` (11 LogOut, 15 AuthRequest, 16 AuthRequestResponse…).
  final int type;

  /// Device id of the device that caused the event (may be null).
  final String? contextId;

  /// Event payload (keys as sent by the server, e.g. `Id`, `UserId`, `Date`,
  /// `Reason`). Timestamps are decoded to UTC [DateTime]s.
  final Map<String, Object?> payload;

  bool get isLogOut => type == kLogOutNotificationType;
  bool get isAuthRequest => type == kAuthRequestNotificationType;
  bool get isAuthRequestResponse =>
      type == kAuthRequestResponseNotificationType;

  /// LogOut reason (bitwarden.com: 0 = KDF change, 1 = key rotation);
  /// null when not sent (Vaultwarden).
  int? get logOutReason => isLogOut ? jsonInt(payload, 'Reason') : null;

  /// Auth request id for types 15/16.
  String? get authRequestId => jsonString(payload, 'Id');

  String? get userId => jsonString(payload, 'UserId');

  DateTime? get date {
    final d = jsonGet(payload, 'Date');
    if (d is DateTime) return d;
    return parseServerDate(d);
  }

  @override
  String toString() => 'HubEvent(type: $type)';
}

/// Connection state of the notifications hub.
enum HubConnectionState {
  /// Not connected and not trying (no session, logged out or reset).
  disconnected,

  /// Opening the socket / waiting for the SignalR handshake.
  connecting,

  /// Handshake done; events flow.
  connected,

  /// Waiting before the next reconnect attempt (exponential backoff).
  backingOff,

  /// Paused by the app (background).
  paused,

  /// The server rejected the token and no newer token is available yet;
  /// waits for `updateToken` / `connect`.
  waitingForToken,
}
