import '../utils/constants.dart';
import 'json_util.dart';

/// A pending "Login with device" auth request.
///
/// Time handling: [creationDate] is UTC server time. [serverClockOffset] is
/// `serverNow − localNow` measured when the list was fetched (HTTP `Date`
/// header or `GET /api/now`), so age and countdown are computed against the
/// server's clock, not the phone's.
class AuthRequest {
  final String id;
  final String publicKey;
  final String requestDeviceType;
  final String requestIpAddress;

  /// UTC. When the server sent no (parseable) creation date this is the Unix
  /// epoch and [hasCreationDate] is false — such a request is never
  /// actionable.
  final DateTime creationDate;
  final bool hasCreationDate;

  /// Fingerprint phrase for this request's public key and the account email.
  /// Null when it could not be computed (malformed key) — the request must
  /// then not be approved.
  final String? fingerprint;

  /// Requesting device's identifier (bitwarden.com only; Vaultwarden omits it).
  final String? requestDeviceIdentifier;

  /// Numeric Bitwarden DeviceType (bitwarden.com `requestDeviceTypeValue`).
  final int? requestDeviceTypeValue;

  /// bitwarden.com `requestCountryName`.
  final String? requestCountryName;

  /// null = pending; bitwarden.com reports `false` for both pending and
  /// denied (denied has a [responseDate]).
  final bool? requestApproved;
  final DateTime? responseDate;
  final String? origin;

  /// `serverNow − localNow` at fetch time.
  final Duration serverClockOffset;

  static final DateTime _missingDate =
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  AuthRequest({
    required this.id,
    required this.publicKey,
    required this.requestDeviceType,
    required this.requestIpAddress,
    required DateTime creationDate,
    this.fingerprint,
    this.hasCreationDate = true,
    this.requestDeviceIdentifier,
    this.requestDeviceTypeValue,
    this.requestCountryName,
    this.requestApproved,
    this.responseDate,
    this.origin,
    this.serverClockOffset = Duration.zero,
  }) : creationDate = creationDate.toUtc();

  /// Lenient parser for one list item (any key casing). Returns null when the
  /// item has no usable `id` or `publicKey` — such items are skipped.
  static AuthRequest? tryParse(
    Map<String, dynamic> json, {
    Duration serverClockOffset = Duration.zero,
  }) {
    final id = jsonNonEmptyString(json, 'id');
    final publicKey = jsonNonEmptyString(json, 'publicKey');
    if (id == null || publicKey == null) return null;
    final created = parseServerDate(jsonGet(json, 'creationDate'));
    return AuthRequest(
      id: id,
      publicKey: publicKey,
      requestDeviceType:
          jsonNonEmptyString(json, 'requestDeviceType') ?? 'Unknown',
      requestIpAddress: jsonString(json, 'requestIpAddress') ?? '',
      creationDate: created ?? _missingDate,
      hasCreationDate: created != null,
      requestDeviceIdentifier:
          jsonNonEmptyString(json, 'requestDeviceIdentifier'),
      requestDeviceTypeValue: jsonInt(json, 'requestDeviceTypeValue'),
      requestCountryName: jsonNonEmptyString(json, 'requestCountryName'),
      requestApproved: jsonBool(json, 'requestApproved'),
      responseDate: parseServerDate(jsonGet(json, 'responseDate')),
      origin: jsonNonEmptyString(json, 'origin'),
      serverClockOffset: serverClockOffset,
    );
  }

  /// Strict parser: throws [FormatException] when `id`/`publicKey` are missing.
  factory AuthRequest.fromJson(
    Map<String, dynamic> json, {
    Duration serverClockOffset = Duration.zero,
  }) {
    final r = tryParse(json, serverClockOffset: serverClockOffset);
    if (r == null) {
      throw const FormatException('Auth request without id or publicKey');
    }
    return r;
  }

  AuthRequest copyWith({String? fingerprint, Duration? serverClockOffset}) =>
      AuthRequest(
        id: id,
        publicKey: publicKey,
        requestDeviceType: requestDeviceType,
        requestIpAddress: requestIpAddress,
        creationDate: creationDate,
        fingerprint: fingerprint ?? this.fingerprint,
        hasCreationDate: hasCreationDate,
        requestDeviceIdentifier: requestDeviceIdentifier,
        requestDeviceTypeValue: requestDeviceTypeValue,
        requestCountryName: requestCountryName,
        requestApproved: requestApproved,
        responseDate: responseDate,
        origin: origin,
        serverClockOffset: serverClockOffset ?? this.serverClockOffset,
      );

  /// Server time "now", estimated from the local clock and the offset.
  DateTime serverNow([DateTime? localNow]) =>
      (localNow ?? DateTime.now()).toUtc().add(serverClockOffset);

  /// Server-time instant after which the request can no longer be used.
  DateTime get expiresAt => creationDate.add(kAuthRequestActionableWindow);

  /// Age measured on the server clock.
  Duration age([DateTime? localNow]) =>
      serverNow(localNow).difference(creationDate);

  /// Time left in the 5-minute actionable window (zero when expired or
  /// without a creation date).
  Duration remaining([DateTime? localNow]) {
    if (!hasCreationDate) return Duration.zero;
    final left = expiresAt.difference(serverNow(localNow));
    if (left.isNegative) return Duration.zero;
    return left > kAuthRequestActionableWindow
        ? kAuthRequestActionableWindow
        : left;
  }

  /// Not yet answered (pending).
  bool get isUnanswered => responseDate == null && requestApproved != true;

  /// Can still be approved/denied: unanswered, has a creation date and is
  /// inside the 5-minute window (server clock).
  bool isActionableAt([DateTime? localNow]) =>
      isUnanswered && hasCreationDate && remaining(localNow) > Duration.zero;

  bool get isActionable => isActionableAt();

  /// Whole minutes left, rounded up (0 when expired).
  int get minutesRemaining => (remaining().inSeconds + 59) ~/ 60;

  bool get isExpired => remaining() <= Duration.zero;

  /// F8 list selection: drop answered requests (`responseDate != null` or
  /// `requestApproved == true`), keep only the newest request per
  /// `requestDeviceIdentifier` (when present), drop non-actionable ones
  /// unless [includeExpired], and sort newest first.
  static List<AuthRequest> selectPending(
    Iterable<AuthRequest> all, {
    bool includeExpired = false,
    DateTime? localNow,
  }) {
    final newestByDevice = <String, AuthRequest>{};
    final withoutDevice = <AuthRequest>[];
    for (final r in all) {
      if (!r.isUnanswered) continue;
      final device = r.requestDeviceIdentifier;
      if (device == null) {
        withoutDevice.add(r);
        continue;
      }
      final current = newestByDevice[device];
      if (current == null || r.creationDate.isAfter(current.creationDate)) {
        newestByDevice[device] = r;
      }
    }
    final result = [...newestByDevice.values, ...withoutDevice];
    if (!includeExpired) {
      result.removeWhere((r) => !r.isActionableAt(localNow));
    }
    result.sort((a, b) => b.creationDate.compareTo(a.creationDate));
    return result;
  }
}
