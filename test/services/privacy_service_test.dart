import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/services/privacy_service.dart';

const _privacy = MethodChannel(PrivacyService.channelName);
const _captured = EventChannel(PrivacyService.eventChannelName);

/// Where the plain-clipboard fallback is allowed and the clipboard is never
/// read back.
const _desktop = TargetPlatformVariant({TargetPlatform.macOS});

/// Where a secret must never go to the plain clipboard.
const _mobile = TargetPlatformVariant({
  TargetPlatform.iOS,
  TargetPlatform.android,
});

TestDefaultBinaryMessenger get _messenger =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

/// Fake system clipboard behind `SystemChannels.platform`.
class _FakeClipboard {
  String? text;
  final List<MethodCall> calls = [];
  bool failing = false;

  /// While set, every clipboard call waits for it before taking effect.
  Completer<void>? gate;

  void install() {
    _messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (!call.method.startsWith('Clipboard.')) return null;
      calls.add(call);
      final gate = this.gate;
      if (gate != null) await gate.future;
      if (failing) throw PlatformException(code: 'denied');
      switch (call.method) {
        case 'Clipboard.setData':
          text = (call.arguments as Map)['text'] as String?;
        case 'Clipboard.getData':
          return <String, Object?>{'text': text};
      }
      return null;
    });
  }

  List<String> get methods => [for (final c in calls) c.method];

  List<String?> get writes => [
        for (final c in calls)
          if (c.method == 'Clipboard.setData')
            (c.arguments as Map)['text'] as String?,
      ];
}

/// The native side answers like an unregistered channel.
void _nativeMissing() {
  _messenger.setMockMethodCallHandler(
    _privacy,
    (call) async => throw MissingPluginException(),
  );
}

/// Records native calls and answers with [reply].
List<MethodCall> _nativeRecording([Object? Function(MethodCall)? reply]) {
  final calls = <MethodCall>[];
  _messenger.setMockMethodCallHandler(_privacy, (call) async {
    calls.add(call);
    return reply == null ? true : reply(call);
  });
  return calls;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeClipboard clipboard;
  late PrivacyService service;

  setUp(() {
    clipboard = _FakeClipboard()..install();
    service = PrivacyService();
  });

  tearDown(() {
    _messenger.setMockMethodCallHandler(_privacy, null);
    _messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    _messenger.setMockStreamHandler(_captured, null);
  });

  group('native channel', () {
    test('copySensitive sends text and a 60 s default TTL', () async {
      final calls = _nativeRecording();

      expect(await service.copySensitive('1234'), isTrue);

      expect(calls.single.method, 'copySensitive');
      expect(calls.single.arguments, {'text': '1234', 'ttlSeconds': 60});
      expect(clipboard.calls, isEmpty, reason: 'native path owns the copy');
    });

    test('TTL is rounded up to whole seconds, minimum 1', () async {
      final calls = _nativeRecording();

      await service.copySensitive('a', ttl: const Duration(milliseconds: 1500));
      await service.copySensitive('b', ttl: const Duration(seconds: 30));
      await service.copySensitive('c', ttl: Duration.zero);
      await service.copySensitive('d', ttl: const Duration(seconds: -5));

      expect([
        for (final c in calls) (c.arguments as Map)['ttlSeconds']
      ], [
        2,
        30,
        1,
        1,
      ]);
    });

    test('other methods forward to the channel', () async {
      final calls = _nativeRecording(
        (call) => call.method == 'isScreenCaptured' ? true : null,
      );

      await service.clearClipboardIfOurs();
      await service.clearClipboard();
      await service.setSecureScreen(true);
      await service.setSecureScreen(false);
      final captured = await service.isScreenCaptured();

      expect([
        for (final c in calls) c.method
      ], [
        'clearClipboardIfOurs',
        'clearClipboard',
        'setSecureScreen',
        'setSecureScreen',
        'isScreenCaptured',
      ]);
      expect(calls[2].arguments, {'enabled': true});
      expect(calls[3].arguments, {'enabled': false});
      expect(captured, isTrue);
      expect(clipboard.calls, isEmpty);
    });

    test('isScreenCaptured is false for a null or malformed reply', () async {
      _nativeRecording((_) => null);
      expect(await service.isScreenCaptured(), isFalse);

      _nativeRecording((_) => 'yes');
      expect(await service.isScreenCaptured(), isFalse);
    });

    test('isScreenshotsAllowedBuild relays the native build flag', () async {
      final calls = _nativeRecording(
        (call) => call.method == 'isScreenshotsAllowedBuild' ? true : null,
      );
      expect(await service.isScreenshotsAllowedBuild(), isTrue);
      expect(calls.single.method, 'isScreenshotsAllowedBuild');
      expect(calls.single.arguments, isNull);

      _nativeRecording((_) => false);
      expect(await service.isScreenshotsAllowedBuild(), isFalse);

      // Production builds and iOS answer false; anything else counts as false.
      _nativeRecording((_) => null);
      expect(await service.isScreenshotsAllowedBuild(), isFalse);
      _nativeRecording((_) => 'yes');
      expect(await service.isScreenshotsAllowedBuild(), isFalse);
      _messenger.setMockMethodCallHandler(
        _privacy,
        (call) async => throw PlatformException(code: 'privacy_failed'),
      );
      expect(await service.isScreenshotsAllowedBuild(), isFalse);
    });

    test('setSecureScreen calls nest', () async {
      final calls = _nativeRecording();

      // Tab B appears before tab A goes away, then B goes too.
      await service.setSecureScreen(true);
      await service.setSecureScreen(true);
      await service.setSecureScreen(false);
      await service.setSecureScreen(false);
      // An unmatched release cannot drive the count below zero.
      await service.setSecureScreen(false);
      await service.setSecureScreen(true);

      expect([
        for (final c in calls) (c.arguments as Map)['enabled']
      ], [
        true,
        true,
        true,
        false,
        false,
        true,
      ]);
    });

    test('a method the native side lacks does not disable the others',
        () async {
      final calls = <String>[];
      _messenger.setMockMethodCallHandler(_privacy, (call) async {
        calls.add(call.method);
        if (call.method == 'setSecureScreen') throw MissingPluginException();
        return true;
      });

      await service.setSecureScreen(true);
      expect(await service.copySensitive('5555'), isTrue);
      // The missing method is remembered and not asked again.
      await service.setSecureScreen(false);

      expect(calls, ['setSecureScreen', 'copySensitive']);
      expect(clipboard.calls, isEmpty);
    });

    testWidgets(
      'on iOS and Android a failed native copy is reported, not '
      'downgraded to the plain clipboard',
      (tester) async {
        _messenger.setMockMethodCallHandler(
          _privacy,
          (call) async => throw PlatformException(code: 'privacy_failed'),
        );
        expect(await service.copySensitive('4321'), isFalse);

        _nativeMissing();
        expect(await service.copySensitive('4321'), isFalse);

        expect(clipboard.calls, isEmpty);
      },
      variant: _mobile,
    );

    testWidgets(
      'on desktop a native error falls back to the Flutter clipboard',
      (tester) async {
        _messenger.setMockMethodCallHandler(
          _privacy,
          (call) async => throw PlatformException(code: 'privacy_failed'),
        );

        expect(await service.copySensitive('4321'), isTrue);

        expect(clipboard.text, '4321');
        await service.clearClipboardIfOurs();
        expect(clipboard.writes, ['4321', '']);
      },
      variant: _desktop,
    );
  });

  group('fallback without the native channel', () {
    setUp(_nativeMissing);

    testWidgets(
      'clears the clipboard when the TTL expires',
      (tester) async {
        expect(
          await service.copySensitive(
            '1234',
            ttl: const Duration(seconds: 10),
          ),
          isTrue,
        );
        expect(clipboard.text, '1234');

        await tester.pump(const Duration(seconds: 9));
        expect(clipboard.text, '1234');

        await tester.pump(const Duration(seconds: 1));
        expect(clipboard.text, '');
        expect(clipboard.writes, ['1234', '']);
      },
      variant: _desktop,
    );

    testWidgets(
      'a newer copy is not cleared by the older timer',
      (tester) async {
        await service.copySensitive('old', ttl: const Duration(seconds: 10));
        await tester.pump(const Duration(seconds: 5));
        await service.copySensitive('new', ttl: const Duration(seconds: 60));

        await tester.pump(const Duration(seconds: 10));
        expect(clipboard.text, 'new');

        await tester.pump(const Duration(seconds: 60));
        expect(clipboard.text, '');
        expect(clipboard.writes, ['old', 'new', '']);
      },
      variant: _desktop,
    );

    testWidgets(
      'clearClipboardIfOurs clears now and cancels the timer',
      (tester) async {
        await service.copySensitive('1234');
        await service.clearClipboardIfOurs();
        expect(clipboard.text, '');

        await tester.pump(const Duration(seconds: 120));
        expect(clipboard.writes, ['1234', ''], reason: 'no second clear');
      },
      variant: _desktop,
    );

    testWidgets(
      'a clear issued right after a copy clears that copy',
      (tester) async {
        // E.g. the screen is disposed right after Copy is tapped.
        final copy = service.copySensitive(
          '1234',
          ttl: const Duration(seconds: 30),
        );
        final clear = service.clearClipboardIfOurs();
        await Future.wait([copy, clear]);

        expect(clipboard.text, '');
        expect(clipboard.writes, ['1234', '']);

        await tester.pump(const Duration(seconds: 31));
        expect(clipboard.writes, ['1234', ''], reason: 'timer cancelled');
      },
      variant: _desktop,
    );

    testWidgets(
      'a clear right after a copy also wins after a native error',
      (tester) async {
        _messenger.setMockMethodCallHandler(
          _privacy,
          (call) async => throw PlatformException(code: 'privacy_failed'),
        );

        final copy = service.copySensitive(
          '9999',
          ttl: const Duration(seconds: 30),
        );
        final clear = service.clearClipboardIfOurs();
        await Future.wait([copy, clear]);

        expect(clipboard.text, '');
        expect(clipboard.writes, ['9999', '']);
      },
      variant: _desktop,
    );

    testWidgets(
      'calls issued without awaiting take effect in call order',
      (tester) async {
        final results = Future.wait([
          service.copySensitive('a', ttl: const Duration(seconds: 10)),
          service.clearClipboardIfOurs(),
          service.copySensitive('b', ttl: const Duration(seconds: 20)),
        ]);
        await results;
        expect(clipboard.text, 'b');
        expect(clipboard.writes, ['a', '', 'b']);

        await tester.pump(const Duration(seconds: 20));
        expect(clipboard.writes, ['a', '', 'b', '']);
      },
      variant: _desktop,
    );

    testWidgets(
      'an expiry that fires behind a queued copy leaves that copy alone',
      (tester) async {
        final gate = Completer<void>();
        _messenger.setMockMethodCallHandler(_privacy, (call) async {
          if (call.method == 'clearClipboardIfOurs') await gate.future;
          throw MissingPluginException();
        });

        await service.copySensitive('old', ttl: const Duration(seconds: 5));
        // The clear waits on the native side; the new copy queues behind it.
        final clear = service.clearClipboardIfOurs();
        final copy = service.copySensitive(
          'new',
          ttl: const Duration(seconds: 60),
        );
        // The old expiry fires now and queues behind the new copy.
        await tester.pump(const Duration(seconds: 5));
        expect(clipboard.writes, ['old']);

        gate.complete();
        await clear;
        expect(await copy, isTrue);
        await tester.pump();

        expect(clipboard.text, 'new');
        expect(clipboard.writes, ['old', '', 'new']);

        await tester.pump(const Duration(seconds: 60));
        expect(clipboard.writes, ['old', '', 'new', '']);
      },
      variant: _desktop,
    );

    testWidgets(
      'clearClipboardIfOurs with nothing copied does nothing',
      (tester) async {
        clipboard.text = 'user text';
        await service.clearClipboardIfOurs();
        expect(clipboard.calls, isEmpty);
        expect(clipboard.text, 'user text');
      },
      variant: _desktop,
    );

    testWidgets('clearClipboard clears unconditionally, also on mobile', (
      tester,
    ) async {
      // Clearing needs no expiry or sensitivity, so the plain clipboard is
      // fine for it everywhere (tests run as Android).
      clipboard.text = 'pasted seed';
      await service.clearClipboard();
      expect(clipboard.text, '');
    });

    testWidgets(
      'on iOS and Android a missing channel is reported as a failed copy',
      (tester) async {
        expect(await service.copySensitive('1234'), isFalse);
        expect(clipboard.calls, isEmpty);
      },
      variant: _mobile,
    );

    testWidgets(
      'never reads the clipboard on macOS',
      (tester) async {
        await service.copySensitive('1234', ttl: const Duration(seconds: 5));
        // Someone else copies; without a silent read we still believe it is
        // ours and clear it: the documented trade-off of the fallback.
        clipboard.text = 'other';
        await tester.pump(const Duration(seconds: 5));

        expect(clipboard.methods, isNot(contains('Clipboard.getData')));
        expect(clipboard.text, '');
      },
      variant: _desktop,
    );

    testWidgets(
      'on desktop leaves a newer clipboard value alone',
      (tester) async {
        await service.copySensitive('1234', ttl: const Duration(seconds: 5));
        clipboard.text = 'other';
        await tester.pump(const Duration(seconds: 5));

        expect(clipboard.methods, contains('Clipboard.getData'));
        expect(clipboard.text, 'other');
        expect(clipboard.writes, ['1234']);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.linux),
    );

    testWidgets(
      'on desktop clears when the value is unchanged',
      (tester) async {
        await service.copySensitive('1234', ttl: const Duration(seconds: 5));
        await tester.pump(const Duration(seconds: 5));
        expect(clipboard.text, '');
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets('screen methods are harmless no-ops', (tester) async {
      await service.setSecureScreen(true);
      expect(await service.isScreenCaptured(), isFalse);
      expect(await service.isScreenshotsAllowedBuild(), isFalse);
      expect(clipboard.calls, isEmpty);
    });

    testWidgets(
      'never throws when the clipboard itself fails',
      (tester) async {
        clipboard.failing = true;

        expect(await service.copySensitive('1234'), isFalse);
        await service.clearClipboardIfOurs();
        await service.clearClipboard();

        // A failed write schedules no clear, so no timer is left pending.
        expect(clipboard.writes, ['1234', '']);
      },
      variant: _desktop,
    );
  });

  group('dispose', () {
    setUp(_nativeMissing);

    testWidgets(
      'disposing the provider cancels the expiry timer and clears the copy',
      (tester) async {
        final container = ProviderContainer();
        final privacy = container.read(privacyServiceProvider);
        expect(await privacy.copySensitive('1234'), isTrue);

        container.dispose();
        await tester.pump();

        // A pending timer would also fail this test on its own.
        expect(clipboard.text, '');
        expect(clipboard.writes, ['1234', '']);
      },
      variant: _desktop,
    );

    testWidgets(
      'disposing while the copy is being written takes it back',
      (tester) async {
        final gate = clipboard.gate = Completer<void>();
        final copy = service.copySensitive('1234');
        await tester.pump();
        expect(clipboard.writes, ['1234'], reason: 'write in flight');

        service.dispose();
        clipboard.gate = null;
        gate.complete();

        expect(await copy, isFalse);
        expect(clipboard.text, '');
        expect(clipboard.writes, ['1234', '']);
      },
      variant: _desktop,
    );

    testWidgets(
      'disposing while the native call is in flight writes nothing',
      (tester) async {
        final gate = Completer<void>();
        _messenger.setMockMethodCallHandler(_privacy, (call) async {
          await gate.future;
          throw MissingPluginException();
        });

        final copy = service.copySensitive('1234');
        service.dispose();
        gate.complete();

        expect(await copy, isFalse);
        expect(clipboard.calls, isEmpty);
      },
      variant: _desktop,
    );

    test('copySensitive after dispose does nothing', () async {
      final calls = _nativeRecording();
      service
        ..dispose()
        ..dispose();

      expect(await service.copySensitive('1234'), isFalse);
      await service.clearClipboard();

      expect([for (final c in calls) c.method], ['clearClipboard']);
    });
  });

  group('events', () {
    test('decodeEvent maps the wire values', () {
      expect(PrivacyService.decodeEvent(true), const CaptureChanged(true));
      expect(PrivacyService.decodeEvent(false), const CaptureChanged(false));
      expect(PrivacyService.decodeEvent('screenshot'), const ScreenshotTaken());
      expect(PrivacyService.decodeEvent('other'), isNull);
      expect(PrivacyService.decodeEvent(1), isNull);
      expect(PrivacyService.decodeEvent(null), isNull);
      expect(PrivacyService.decodeEvent({'captured': true}), isNull);
    });

    test('decodes native events and drops unknown ones and errors', () async {
      _messenger.setMockStreamHandler(
        _captured,
        MockStreamHandler.inline(
          onListen: (arguments, sink) {
            sink.success(false);
            sink.success('screenshot');
            sink.success('something new');
            sink.success(42);
            sink.error(code: 'boom');
            sink.success(true);
          },
        ),
      );

      final received = <PrivacyEvent>[];
      final errors = <Object>[];
      final sub = service.events.listen(received.add, onError: errors.add);
      await pumpEventQueue();
      await sub.cancel();

      expect(received, const [
        CaptureChanged(false),
        ScreenshotTaken(),
        CaptureChanged(true),
      ]);
      expect(errors, isEmpty);
    });

    test('listeners share one native subscription', () async {
      final nativeCalls = <String>[];
      _messenger.setMockStreamHandler(
        _captured,
        MockStreamHandler.inline(
          onListen: (arguments, sink) {
            nativeCalls.add('listen');
            sink.success(true);
          },
          onCancel: (arguments) => nativeCalls.add('cancel'),
        ),
      );

      final a = <PrivacyEvent>[];
      final b = <PrivacyEvent>[];
      final subA = service.events.listen(a.add);
      // A second instance (e.g. a test override) shares the same source.
      final subB = PrivacyService().events.listen(b.add);
      await pumpEventQueue();

      expect(nativeCalls, ['listen']);
      expect(a, const [CaptureChanged(true)]);
      expect(b, const [CaptureChanged(true)]);

      await subA.cancel();
      await pumpEventQueue();
      expect(nativeCalls, ['listen'], reason: 'B is still listening');

      await subB.cancel();
      await pumpEventQueue();
      expect(nativeCalls, ['listen', 'cancel']);
    });

    test('a listener that joins late first gets the current capture state',
        () async {
      final nativeCalls = <String>[];
      late MockStreamHandlerEventSink native;
      _messenger.setMockStreamHandler(
        _captured,
        MockStreamHandler.inline(
          onListen: (arguments, sink) {
            nativeCalls.add('listen');
            native = sink;
            sink.success(true);
            sink.success('screenshot');
          },
          onCancel: (arguments) => nativeCalls.add('cancel'),
        ),
      );

      final a = <PrivacyEvent>[];
      final b = <PrivacyEvent>[];
      final subA = service.events.listen(a.add);
      await pumpEventQueue();
      // E.g. a second PIN screen mounted while recording is already on.
      final subB = PrivacyService().events.listen(b.add);
      await pumpEventQueue();

      expect(nativeCalls, ['listen']);
      expect(a, const [CaptureChanged(true), ScreenshotTaken()]);
      expect(b, const [CaptureChanged(true)], reason: 'no screenshot replay');

      native.success(false);
      await pumpEventQueue();
      expect(a, const [
        CaptureChanged(true),
        ScreenshotTaken(),
        CaptureChanged(false),
      ]);
      expect(b, const [CaptureChanged(true), CaptureChanged(false)]);

      await subA.cancel();
      await subB.cancel();
      await pumpEventQueue();
      expect(nativeCalls, ['listen', 'cancel']);
    });

    test('the replayed state is forgotten when the last listener leaves',
        () async {
      var listens = 0;
      _messenger.setMockStreamHandler(
        _captured,
        MockStreamHandler.inline(
          onListen: (arguments, sink) {
            listens++;
            // Only the first subscription reports a state.
            if (listens == 1) sink.success(true);
          },
        ),
      );

      final first = <PrivacyEvent>[];
      var sub = service.events.listen(first.add);
      await pumpEventQueue();
      await sub.cancel();
      await pumpEventQueue();

      final second = <PrivacyEvent>[];
      sub = service.events.listen(second.add);
      await pumpEventQueue();
      await sub.cancel();
      await pumpEventQueue();

      expect(listens, 2);
      expect(first, const [CaptureChanged(true)]);
      expect(second, isEmpty, reason: 'stale state not replayed');
    });

    test('an end-of-stream message does not close the shared stream', () async {
      _messenger.setMockStreamHandler(
        _captured,
        MockStreamHandler.inline(
          onListen: (arguments, sink) {
            sink.success(true);
            sink.endOfStream();
          },
        ),
      );

      var done = false;
      final sub = service.events.listen((_) {}, onDone: () => done = true);
      await pumpEventQueue();
      await sub.cancel();

      expect(done, isFalse);
    });

    test('a missing native side is silent and reports no error', () async {
      _messenger.setMockMethodCallHandler(
        const MethodChannel(PrivacyService.eventChannelName),
        (call) async => throw MissingPluginException(),
      );
      final reported = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = reported.add;
      addTearDown(() => FlutterError.onError = previous);

      final received = <PrivacyEvent>[];
      final errors = <Object>[];
      final sub = service.events.listen(received.add, onError: errors.add);
      await pumpEventQueue();
      await sub.cancel();
      await pumpEventQueue();

      expect(received, isEmpty);
      expect(errors, isEmpty);
      expect(reported, isEmpty);
      _messenger.setMockMethodCallHandler(
        const MethodChannel(PrivacyService.eventChannelName),
        null,
      );
    });
  });

  test('privacyServiceProvider exposes one PrivacyService', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final first = container.read(privacyServiceProvider);
    expect(first, isA<PrivacyService>());
    expect(container.read(privacyServiceProvider), same(first));
  });
}
