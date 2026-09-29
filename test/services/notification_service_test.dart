import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/models/api_error.dart';
import 'package:vault_approver/models/server_environment.dart';
import 'package:vault_approver/services/notification_service.dart';

/// Minimal Vaultwarden-like SignalR hub (src/api/notifications.rs): checks
/// `access_token` at the upgrade (401 otherwise), answers the MessagePack
/// handshake with a binary `{}\x1e`, echoes nothing else.
class _Hub {
  late HttpServer server;
  final validTokens = <String>{'good'};
  final upgrades = <Uri>[];
  final sockets = <WebSocket>[];
  final received = <Object?>[];
  List<int> handshakeReply = [0x7b, 0x7d, 0x1e];
  String pathPrefix = '';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      upgrades.add(request.uri);
      if (request.uri.path != '$pathPrefix/notifications/hub') {
        request.response.statusCode = 404;
        await request.response.close();
        return;
      }
      final token = request.uri.queryParameters['access_token'];
      if (!validTokens.contains(token)) {
        request.response.statusCode = 401;
        await request.response.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(request);
      sockets.add(ws);
      ws.listen((message) {
        received.add(message);
        if (message is String && message.contains('"messagepack"')) {
          ws.add(Uint8List.fromList(handshakeReply));
        }
      });
    });
  }

  String get base => 'http://127.0.0.1:${server.port}$pathPrefix';

  int get connections => sockets.length;

  void broadcast(Uint8List frame) {
    for (final ws in sockets) {
      if (ws.readyState == WebSocket.open) ws.add(frame);
    }
  }

  Future<void> closeAll() async {
    for (final ws in sockets) {
      await ws.close();
    }
  }

  Future<void> stop() => server.close(force: true);
}

Uint8List _invocation(List<Map<String, Object?>> args) =>
    NotificationService.encodeFrame(
        [1, <String, Object?>{}, null, 'ReceiveMessage', args]);

Map<String, Object?> _notification(int type, [Map<String, Object?>? payload]) =>
    {
      'ContextId': null,
      'Type': type,
      'Payload': payload ?? {'Id': 'req-$type', 'UserId': 'u1'},
    };

Future<T> _within<T>(Future<T> f) => f.timeout(const Duration(seconds: 5));

void main() {
  late _Hub hub;
  late NotificationService service;

  NotificationService make({
    HubTokenProvider? tokenProvider,
    Duration pingInterval = const Duration(seconds: 15),
    Duration initialBackoff = const Duration(milliseconds: 20),
  }) =>
      NotificationService(
        tokenProvider: tokenProvider,
        pingInterval: pingInterval,
        initialBackoff: initialBackoff,
        maxBackoff: const Duration(milliseconds: 400),
        handshakeTimeout: const Duration(seconds: 2),
      );

  Future<void> reach(NotificationService s, HubConnectionState target) async {
    if (s.state == target) return;
    await _within(s.states.firstWhere((x) => x == target));
  }

  Future<void> connected(NotificationService s) =>
      reach(s, HubConnectionState.connected);

  setUp(() async {
    hub = _Hub();
    await hub.start();
  });

  tearDown(() async {
    service.dispose();
    await hub.stop();
  });

  test('connects with the handshake and emits Type 15', () async {
    service = make();
    final types = <int>[];
    service.onNotification.listen(types.add);
    await service.connect(hub.base, 'good');
    await connected(service);
    expect(hub.upgrades.single.path, '/notifications/hub');
    expect(hub.upgrades.single.queryParameters['access_token'], 'good');
    expect(hub.received.first, '{"protocol":"messagepack","version":1}\x1e');

    final event = _within(service.events.first);
    hub.broadcast(_invocation([_notification(15)]));
    final e = await event;
    expect(e.isAuthRequest, isTrue);
    expect(e.authRequestId, 'req-15');
    expect(e.userId, 'u1');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(types, [15]);
  });

  test('custom path is kept in the hub URL (compatible_ok)', () async {
    await hub.stop();
    hub = _Hub()..pathPrefix = '/vault';
    await hub.start();
    service = make();
    await service.connect(hub.base, 'good');
    await connected(service);
    expect(hub.upgrades.single.path, '/vault/notifications/hub');
  });

  test('parses ALL messages of a frame; LogOut with Reason, Type 16 (A9, A10)',
      () async {
    service = make();
    await service.connect(hub.base, 'good');
    await connected(service);
    final events = <HubEvent>[];
    service.events.listen(events.add);
    final logOuts = <HubEvent>[];
    service.onLogOut.listen(logOuts.add);

    final frame = BytesBuilder()
      ..add(_invocation([_notification(16)]))
      ..add(NotificationService.encodeFrame([6])) // ping, ignored
      ..add(_invocation([
        _notification(11, {'UserId': 'u1', 'Reason': 1}),
        _notification(15),
      ]));
    hub.broadcast(frame.toBytes());
    await _within(service.events.take(3).toList());
    expect(events.map((e) => e.type), [16, 11, 15]);
    expect(events[0].isAuthRequestResponse, isTrue);
    expect(logOuts.single.logOutReason, 1);
    expect(logOuts.single.isLogOut, isTrue);
  });

  test('handshake reply and first message in one frame', () async {
    hub.handshakeReply = [
      0x7b,
      0x7d,
      0x1e,
      ..._invocation([_notification(15)])
    ];
    service = make();
    final first = _within(service.events.first);
    await service.connect(hub.base, 'good');
    expect((await first).type, 15);
  });

  test('sends SignalR pings', () async {
    service = make(pingInterval: const Duration(milliseconds: 40));
    await service.connect(hub.base, 'good');
    await connected(service);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final pings = hub.received
        .whereType<List<int>>()
        .where((m) => m.length == 3 && m[0] == 2 && m[1] == 0x91 && m[2] == 6);
    expect(pings.length, greaterThanOrEqualTo(2));
  });

  test('401 on the upgrade → asks for a refreshed token (F10)', () async {
    final calls = <bool>[];
    var token = 'expired';
    service = make(
      tokenProvider: ({bool forceRefresh = false}) async {
        calls.add(forceRefresh);
        if (forceRefresh) token = 'good';
        return token;
      },
    );
    await service.connectEnvironment(ServerEnvironment.selfHosted(hub.base));
    await connected(service);
    expect(calls, [false, true]);
    expect(
      hub.upgrades.map((u) => u.queryParameters['access_token']),
      ['expired', 'good'],
    );
  });

  test('static token rejected → waits for updateToken, no retry loop',
      () async {
    service = make();
    await service.connect(hub.base, 'stale');
    await reach(service, HubConnectionState.waitingForToken);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(hub.upgrades, hasLength(1));
    service.updateToken('good');
    await connected(service);
    expect(hub.upgrades, hasLength(2));
  });

  test('token provider SessionEnded → stays offline', () async {
    var calls = 0;
    service = make(
      tokenProvider: ({bool forceRefresh = false}) async {
        calls++;
        throw const SessionEndedException(
          reason: SessionEndReason.refreshTokenRejected,
        );
      },
    );
    await service.connectEnvironment(ServerEnvironment.selfHosted(hub.base));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(service.state, HubConnectionState.disconnected);
    expect(calls, 1);
    expect(hub.upgrades, isEmpty);
  });

  test('no session (null token) → no connection', () async {
    service = make(tokenProvider: ({bool forceRefresh = false}) async => null);
    await service.connectEnvironment(ServerEnvironment.selfHosted(hub.base));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(hub.upgrades, isEmpty);
    expect(service.state, HubConnectionState.disconnected);
  });

  test('exponential backoff on failures', () async {
    hub.validTokens.clear();
    // Provider keeps returning new but rejected tokens → every attempt fails.
    var n = 0;
    service = make(
      tokenProvider: ({bool forceRefresh = false}) async => 'bad-${n++}',
    );
    await service.connectEnvironment(ServerEnvironment.selfHosted(hub.base));
    await Future<void>.delayed(const Duration(milliseconds: 700));
    // 20+40+80+160+320(capped 400) ms → about 5–6 attempts, not ~35 (every 20 ms).
    expect(hub.upgrades.length, inInclusiveRange(3, 7));
  });

  test('reconnects after the server closes, with a fresh token', () async {
    var n = 0;
    hub.validTokens.addAll(['t0', 't1']);
    service =
        make(tokenProvider: ({bool forceRefresh = false}) async => 't${n++}');
    await service.connectEnvironment(ServerEnvironment.selfHosted(hub.base));
    await connected(service);
    final reconnected = _within(
        service.states.where((s) => s == HubConnectionState.connected).first);
    await hub.closeAll();
    await reconnected;
    expect(
      hub.upgrades.map((u) => u.queryParameters['access_token']),
      ['t0', 't1'],
    );
  });

  test('handshake error → backs off and retries', () async {
    hub.handshakeReply = '{"error":"nope"}\x1e'.codeUnits;
    service = make();
    await service.connect(hub.base, 'good');
    await reach(service, HubConnectionState.backingOff);
    expect(service.isConnected, isFalse);
  });

  test('duplicate connect/resume while connected → one socket (F10)', () async {
    service = make();
    await service.connect(hub.base, 'good');
    await connected(service);
    await service.connect(hub.base, 'good');
    service.resume();
    service.updateToken('good');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(hub.connections, 1);
  });

  test('concurrent connects are serialised (only the latest survives)',
      () async {
    service = make();
    unawaited(service.connect(hub.base, 'good'));
    service.resume();
    unawaited(service.connect(hub.base, 'good'));
    await connected(service);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final open =
        hub.sockets.where((s) => s.readyState == WebSocket.open).length;
    expect(open, 1);
  });

  test('pause closes, resume reconnects', () async {
    service = make();
    await service.connect(hub.base, 'good');
    await connected(service);
    service.pause();
    expect(service.state, HubConnectionState.paused);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(hub.upgrades, hasLength(1));
    service.resume();
    await connected(service);
    expect(hub.upgrades, hasLength(2));
  });

  test('reset forgets the server: resume does not reconnect (F10)', () async {
    service = make();
    await service.connect(hub.base, 'good');
    await connected(service);
    service.reset();
    service.resume();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(hub.upgrades, hasLength(1));
    expect(service.environment, isNull);
    expect(service.state, HubConnectionState.disconnected);
  });

  group('framing', () {
    test('encode/decode roundtrip, truncated tail ignored', () {
      final a = NotificationService.encodeFrame([6]);
      final b = NotificationService.encodeFrame([1, {}, null, 'X', []]);
      final both = Uint8List.fromList([...a, ...b, 0x10, 0x01]);
      final decoded = NotificationService.decodeFrame(both);
      expect(decoded, hasLength(2));
      expect(decoded[0], [6]);
    });

    test('long messages use a multi-byte length prefix', () {
      final big = 'x' * 300;
      final frame = NotificationService.encodeFrame([big]);
      expect(frame[0] & 0x80, 0x80);
      expect(NotificationService.decodeFrame(frame).single, [big]);
    });

    test('MessagePack timestamps (Vaultwarden serialize_date) → DateTime', () {
      final when = DateTime.utc(2026, 9, 26, 12, 30, 15, 250);
      final seconds = when.millisecondsSinceEpoch ~/ 1000;
      final nanos = (when.microsecondsSinceEpoch % 1000000) * 1000;
      final ts = (nanos << 34) | seconds;
      final bd = ByteData(8)..setUint64(0, ts);
      // [6, <fixext8 type -1>]
      final payload = [0x92, 0x06, 0xd7, 0xff, ...bd.buffer.asUint8List()];
      final frame = Uint8List.fromList([payload.length, ...payload]);
      final decoded = NotificationService.decodeFrame(frame).single as List;
      expect(decoded[1], when);
    });

    test('eventFromArgument tolerates junk', () {
      expect(NotificationService.eventFromArgument('x'), isNull);
      expect(NotificationService.eventFromArgument({'Type': 'x'}), isNull);
      final e = NotificationService.eventFromArgument(
        {
          'type': 16,
          'contextId': 'dev',
          'payload': {'Id': 'r'}
        },
      )!;
      expect(e.type, 16);
      expect(e.contextId, 'dev');
      expect(e.authRequestId, 'r');
    });
  });
}
