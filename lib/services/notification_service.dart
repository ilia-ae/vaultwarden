import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:msgpack_dart/msgpack_dart.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/api_error.dart';
import '../models/hub_event.dart';
import '../models/json_util.dart';
import '../models/server_environment.dart';
import '../utils/constants.dart';
import 'client_cert_service.dart';

export '../models/hub_event.dart';

/// Returns an access token for the hub (null = no session → stay offline).
/// With `forceRefresh` the previous token was rejected by the hub (HTTP 401
/// on the upgrade) and a refreshed one is wanted. May throw
/// [SessionEndedException] — the hub then stops until [NotificationService.connect]
/// or [NotificationService.updateToken].
typedef HubTokenProvider = Future<String?> Function({bool forceRefresh});

/// Opens the WebSocket (tests inject fakes; the default applies the client
/// certificate of the server origin).
typedef HubChannelFactory = Future<WebSocketChannel> Function(Uri uri);

/// Connects to the server's SignalR notifications hub to receive
/// real-time auth request notifications.
///
/// Protocol: SignalR with MessagePack serialization; handshake
/// `{"protocol":"messagepack","version":1}\x1e`, reply `{}\x1e` (text or
/// binary). Every binary frame may carry several length-prefixed messages
/// (all are parsed). Ping (type 6) every 15 s.
///
/// Connection management: a fresh token is requested for every connect;
/// connects are serialised by a generation counter (only the latest attempt
/// survives); failures back off exponentially (2 s … 5 min); an HTTP 401 on
/// the upgrade asks for a refreshed token and, without one, waits for
/// [updateToken]. Fallback: polling (handled by the provider layer).
class NotificationService {
  NotificationService({
    HubTokenProvider? tokenProvider,
    HubChannelFactory? channelFactory,
    ClientCertService? clientCerts,
    this.pingInterval = kHubPingInterval,
    this.initialBackoff = const Duration(seconds: 2),
    this.maxBackoff = const Duration(minutes: 5),
    this.handshakeTimeout = const Duration(seconds: 15),
    this.stableConnection = const Duration(seconds: 60),
  })  : _tokenProvider = tokenProvider,
        _certs = clientCerts ?? ClientCertService.instance {
    _channelFactory = channelFactory ?? _defaultChannel;
    _certSub = _certs.changes.listen(_onCertificateChanged);
  }

  final Duration pingInterval;
  final Duration initialBackoff;
  final Duration maxBackoff;
  final Duration handshakeTimeout;

  /// A connection that lived this long resets the backoff.
  final Duration stableConnection;

  final ClientCertService _certs;
  late final HubChannelFactory _channelFactory;
  StreamSubscription<String>? _certSub;

  HubTokenProvider? _tokenProvider;
  ServerEnvironment? _env;
  String? _staticToken;
  String? _rejectedToken;
  bool _forceRefreshNext = false;
  bool _paused = false;

  int _generation = 0;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _pingTimer;
  Timer? _handshakeTimer;
  Timer? _reconnectTimer;
  bool _handshakeDone = false;
  int _backoffAttempt = 0;
  DateTime? _connectedAt;
  HubConnectionState _state = HubConnectionState.disconnected;

  final _types = StreamController<int>.broadcast();
  final _events = StreamController<HubEvent>.broadcast();
  final _states = StreamController<HubConnectionState>.broadcast();

  static const _handshake = '{"protocol":"messagepack","version":1}\x1e';

  /// Length-prefixed MessagePack `[6]` (SignalR ping).
  static final Uint8List _pingFrame = encodeFrame(const [6]);

  /// Emits notification type IDs (11 = LogOut, 15 = AuthRequest,
  /// 16 = AuthRequestResponse, …).
  Stream<int> get onNotification => _types.stream;

  /// Full events (type, context id, payload — e.g. LogOut `Reason`).
  Stream<HubEvent> get events => _events.stream;

  /// Only LogOut (type 11) events (A9).
  Stream<HubEvent> get onLogOut => _events.stream.where((e) => e.isLogOut);

  Stream<HubConnectionState> get states => _states.stream;
  HubConnectionState get state => _state;

  /// Handshake completed and the socket is open.
  bool get isConnected => _state == HubConnectionState.connected;

  ServerEnvironment? get environment => _env;

  /// Sets the token source used for every (re)connect.
  void setTokenProvider(HubTokenProvider? provider) {
    _tokenProvider = provider;
  }

  /// Connect to `/notifications/hub` of [serverUrl] (self-hosted) or the
  /// cloud notifications host. [accessToken] is used only when no token
  /// provider is set. No-op when already connected/connecting to the same
  /// server (drops duplicate connect/resume calls).
  Future<void> connect(String serverUrl, String accessToken) {
    _staticToken = accessToken;
    return connectEnvironment(ServerEnvironment.fromUrl(serverUrl));
  }

  /// Like [connect] but with an explicit environment / token provider.
  Future<void> connectEnvironment(
    ServerEnvironment env, {
    HubTokenProvider? tokenProvider,
  }) async {
    if (tokenProvider != null) _tokenProvider = tokenProvider;
    final same = env == _env;
    _env = env;
    _paused = false;
    if (same &&
        (_state == HubConnectionState.connected ||
            _state == HubConnectionState.connecting)) {
      return;
    }
    _backoffAttempt = 0;
    await _doConnect();
  }

  /// New access token (after a refresh). An established connection is kept
  /// (the hub checks the token only at the upgrade); a connection waiting
  /// for a new token or backing off reconnects right away.
  void updateToken(String newAccessToken) {
    _staticToken = newAccessToken;
    if (newAccessToken == _rejectedToken) return;
    if (_paused || _env == null) return;
    if (_state == HubConnectionState.waitingForToken ||
        _state == HubConnectionState.backingOff ||
        _state == HubConnectionState.disconnected) {
      _backoffAttempt = 0;
      _doConnect();
    }
  }

  /// Stop (e.g. logout) but remember the server; [resume] reconnects.
  void disconnect() {
    _paused = true;
    _stop(HubConnectionState.disconnected);
  }

  /// Pause WebSocket (app going to background).
  void pause() {
    _paused = true;
    _stop(HubConnectionState.paused);
  }

  /// Resume WebSocket (app returning to foreground). No-op when already
  /// connected/connecting or when never connected / after [reset].
  void resume() {
    if (_env == null) return;
    _paused = false;
    if (_state == HubConnectionState.connected ||
        _state == HubConnectionState.connecting) {
      return;
    }
    _backoffAttempt = 0;
    _doConnect();
  }

  /// Logout: stop and forget server and tokens, so a later [resume] cannot
  /// reconnect to the previous account. The token provider is kept.
  void reset() {
    _paused = false;
    _stop(HubConnectionState.disconnected);
    _env = null;
    _staticToken = null;
    _rejectedToken = null;
    _forceRefreshNext = false;
    _backoffAttempt = 0;
  }

  void dispose() {
    _stop(HubConnectionState.disconnected);
    _certSub?.cancel();
    _types.close();
    _events.close();
    _states.close();
  }

  // ── Connection ──

  void _stop(HubConnectionState state) {
    _generation++;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _teardownChannel();
    _setState(state);
  }

  void _setState(HubConnectionState s) {
    if (_state == s) return;
    _state = s;
    if (!_states.isClosed) _states.add(s);
  }

  Future<String?> _resolveToken() async {
    final provider = _tokenProvider;
    if (provider == null) return _staticToken;
    final force = _forceRefreshNext;
    _forceRefreshNext = false;
    return provider(forceRefresh: force);
  }

  Future<void> _doConnect() async {
    final env = _env;
    if (env == null || _paused) return;
    final gen = ++_generation;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _teardownChannel();
    _setState(HubConnectionState.connecting);

    final String? token;
    try {
      token = await _resolveToken();
    } on SessionEndedException {
      if (gen == _generation) _setState(HubConnectionState.disconnected);
      return;
    } catch (_) {
      if (gen == _generation) _scheduleReconnect(gen);
      return;
    }
    if (gen != _generation) return;
    if (token == null || token.isEmpty) {
      _setState(HubConnectionState.disconnected);
      return;
    }
    if (token == _rejectedToken) {
      // Still the token the hub refused: wait for a new one.
      _setState(HubConnectionState.waitingForToken);
      return;
    }

    final WebSocketChannel channel;
    try {
      channel = await _channelFactory(env.hubUri(accessToken: token));
      await channel.ready;
    } catch (e) {
      if (gen != _generation) return;
      if (_isUnauthorized(e)) {
        _rejectedToken = token;
        _forceRefreshNext = true;
        if (_tokenProvider == null) {
          _setState(HubConnectionState.waitingForToken);
          return;
        }
      }
      _scheduleReconnect(gen);
      return;
    }
    if (gen != _generation) {
      channel.sink.close();
      return;
    }
    _rejectedToken = null;
    _channel = channel;
    _handshakeDone = false;
    _connectedAt = DateTime.now();
    _sub = channel.stream.listen(
      (message) => _onFrame(gen, message),
      onError: (Object _) => _onClosed(gen),
      onDone: () => _onClosed(gen),
      cancelOnError: true,
    );
    try {
      channel.sink.add(_handshake);
    } catch (_) {
      _onClosed(gen);
      return;
    }
    _handshakeTimer = Timer(handshakeTimeout, () {
      if (gen == _generation && !_handshakeDone) _onClosed(gen);
    });
  }

  void _onClosed(int gen) {
    if (gen != _generation) return;
    final lived = _connectedAt == null
        ? Duration.zero
        : DateTime.now().difference(_connectedAt!);
    final wasUp = _handshakeDone;
    _teardownChannel();
    if (_paused || _env == null) return;
    if (wasUp && lived >= stableConnection) _backoffAttempt = 0;
    _scheduleReconnect(gen);
  }

  void _scheduleReconnect(int gen) {
    if (_paused || _env == null) return;
    final factor = math.pow(2, math.min(_backoffAttempt, 20)).toInt();
    var delay = initialBackoff * factor;
    if (delay > maxBackoff) delay = maxBackoff;
    _backoffAttempt++;
    _setState(HubConnectionState.backingOff);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      if (gen == _generation && !_paused) _doConnect();
    });
  }

  void _teardownChannel() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _handshakeTimer?.cancel();
    _handshakeTimer = null;
    _sub?.cancel();
    _sub = null;
    final ch = _channel;
    _channel = null;
    _handshakeDone = false;
    _connectedAt = null;
    if (ch != null) {
      try {
        ch.sink.close();
      } catch (_) {
        // already closed
      }
    }
  }

  static bool _isUnauthorized(Object e) {
    Object? inner = e;
    if (e is WebSocketChannelException) inner = e.inner ?? e;
    if (inner is WebSocketException) {
      final code = inner.httpStatusCode;
      return code == 401 || code == 403;
    }
    final text = e.toString();
    return text.contains('HTTP status code: 401') ||
        text.contains('HTTP status code: 403');
  }

  // ── Frames ──

  void _onFrame(int gen, dynamic message) {
    if (gen != _generation) return;
    Uint8List? bytes;
    if (message is Uint8List) {
      bytes = message;
    } else if (message is List<int>) {
      bytes = Uint8List.fromList(message);
    } else if (message is String) {
      if (_handshakeDone) return; // JSON protocol was not negotiated
      bytes = Uint8List.fromList(utf8.encode(message));
    } else {
      return;
    }

    if (!_handshakeDone) {
      final sep = bytes.indexOf(0x1e);
      if (sep < 0) return;
      Object? reply;
      try {
        reply = jsonDecode(utf8.decode(bytes.sublist(0, sep)));
      } catch (_) {
        reply = null;
      }
      if (reply is! Map || jsonGet(reply, 'error') != null) {
        _onClosed(gen); // handshake refused → back off
        return;
      }
      _handshakeDone = true;
      _handshakeTimer?.cancel();
      _handshakeTimer = null;
      _setState(HubConnectionState.connected);
      _startPing(gen);
      if (sep + 1 >= bytes.length) return;
      bytes = Uint8List.sublistView(bytes, sep + 1);
    }

    for (final msg in decodeFrame(bytes)) {
      if (gen != _generation) return;
      _handleMessage(gen, msg);
    }
  }

  void _handleMessage(int gen, Object? decoded) {
    if (decoded is! List || decoded.isEmpty) return;
    switch (asInt(decoded[0])) {
      case 1: // Invocation: [1, headers, invocationId, target, arguments]
        if (decoded.length < 5) return;
        final args = decoded[4];
        if (args is! List) return;
        for (final arg in args) {
          final event = eventFromArgument(arg);
          if (event == null) continue;
          _types.add(event.type);
          _events.add(event);
        }
      case 7: // Close
        _onClosed(gen);
      default: // 6 = ping, others ignored
        break;
    }
  }

  void _startPing(int gen) {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(pingInterval, (_) {
      if (gen != _generation) return;
      try {
        _channel?.sink.add(_pingFrame);
      } catch (_) {
        _onClosed(gen);
      }
    });
  }

  void _onCertificateChanged(String origin) {
    final env = _env;
    if (env == null || _paused || env.origin != origin) return;
    _backoffAttempt = 0;
    _doConnect();
  }

  Future<WebSocketChannel> _defaultChannel(Uri uri) async {
    HttpClient? client;
    try {
      final https = uri.replace(scheme: uri.scheme == 'wss' ? 'https' : 'http');
      client = await _certs.createHttpClient(https.toString());
    } catch (_) {
      client = null;
    }
    final channel = IOWebSocketChannel.connect(
      uri,
      customClient: client,
      pingInterval: const Duration(seconds: 30),
      connectTimeout: const Duration(seconds: 15),
    );
    channel.ready.then<void>(
      (_) => client?.close(),
      onError: (Object _) => client?.close(force: true),
    );
    return channel;
  }

  // ── SignalR binary framing (public for tests) ──

  /// Decodes every length-prefixed MessagePack message in [bytes] (A10).
  /// A truncated trailing message is ignored.
  @visibleForTesting
  static List<Object?> decodeFrame(Uint8List bytes) {
    final out = <Object?>[];
    var offset = 0;
    while (offset < bytes.length) {
      var length = 0;
      var shift = 0;
      var i = offset;
      var complete = false;
      while (i < bytes.length && shift <= 28) {
        final b = bytes[i++];
        length |= (b & 0x7f) << shift;
        if (b & 0x80 == 0) {
          complete = true;
          break;
        }
        shift += 7;
      }
      if (!complete || i + length > bytes.length) break;
      try {
        out.add(deserialize(
          Uint8List.sublistView(bytes, i, i + length),
          extDecoder: _TimestampDecoder(),
        ));
      } catch (_) {
        // Skip a malformed message, keep the rest.
      }
      offset = i + length;
    }
    return out;
  }

  /// Length-prefixes a MessagePack-encoded [message].
  @visibleForTesting
  static Uint8List encodeFrame(Object? message) {
    final payload = serialize(message);
    final prefix = <int>[];
    var value = payload.length;
    while (value > 0x7f) {
      prefix.add((value & 0x7f) | 0x80);
      value >>= 7;
    }
    prefix.add(value);
    return Uint8List.fromList([...prefix, ...payload]);
  }

  /// Converts a `ReceiveMessage` argument `{ContextId, Type, Payload}`.
  @visibleForTesting
  static HubEvent? eventFromArgument(Object? arg) {
    if (arg is! Map) return null;
    final type = asInt(jsonGet(arg, 'Type'));
    if (type == null) return null;
    final context = jsonGet(arg, 'ContextId');
    final payload = jsonGet(arg, 'Payload');
    return HubEvent(
      type: type,
      contextId: context is String ? context : null,
      payload: payload is Map
          ? {
              for (final e in payload.entries)
                if (e.key != null) e.key.toString(): e.value,
            }
          : const {},
    );
  }
}

/// Decodes MessagePack timestamps (ext type −1) to UTC [DateTime]s.
class _TimestampDecoder implements ExtDecoder {
  @override
  dynamic decodeObject(int extType, Uint8List data) {
    if (extType != 0xff && extType != -1) return null;
    final bd = ByteData.sublistView(data);
    int seconds;
    var nanos = 0;
    switch (data.length) {
      case 4:
        seconds = bd.getUint32(0);
      case 8:
        final hi = bd.getUint32(0);
        final lo = bd.getUint32(4);
        nanos = hi >> 2;
        seconds = ((hi & 0x3) << 32) | lo;
      case 12:
        nanos = bd.getUint32(0);
        seconds = bd.getInt64(4);
      default:
        return null;
    }
    return DateTime.fromMicrosecondsSinceEpoch(
      seconds * 1000000 + nanos ~/ 1000,
      isUtc: true,
    );
  }
}
