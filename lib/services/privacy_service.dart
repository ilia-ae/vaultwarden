import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Something the platform reported about the screen being captured.
///
/// Delivered by [PrivacyService.events].
sealed class PrivacyEvent {
  const PrivacyEvent();
}

/// Screen recording, AirPlay or mirroring started ([captured] is `true`) or
/// stopped. Only iOS reports this; Android blocks capture with FLAG_SECURE
/// instead.
class CaptureChanged extends PrivacyEvent {
  const CaptureChanged(this.captured);

  final bool captured;

  @override
  bool operator ==(Object other) =>
      other is CaptureChanged && other.captured == captured;

  @override
  int get hashCode => Object.hash(CaptureChanged, captured);

  @override
  String toString() => 'CaptureChanged($captured)';
}

/// The user took a screenshot. iOS always reports this (after the fact, it
/// cannot be blocked); Android 14+ reports it when FLAG_SECURE is off.
class ScreenshotTaken extends PrivacyEvent {
  const ScreenshotTaken();

  @override
  bool operator ==(Object other) => other is ScreenshotTaken;

  @override
  int get hashCode => (ScreenshotTaken).hashCode;

  @override
  String toString() => 'ScreenshotTaken()';
}

/// Secure clipboard and screen-capture awareness for screens that show
/// secrets (the PIN tools).
///
/// Talks to the in-app platform channel registered by
/// `ios/VaultApprover/AppDelegate.swift` and
/// `android/.../MainActivity.kt` (not a plugin, so no
/// GeneratedPluginRegistrant step). Where that channel is missing (desktop,
/// web) [copySensitive] falls back to [Clipboard] plus a Dart timer; on iOS
/// and Android it never does, and reports the failure instead.
///
/// No method ever throws: failures show in return values or degrade to a
/// no-op.
///
/// ## Widget tests
///
/// `testWidgets` runs on a fake clock, and an unmocked platform channel is
/// answered by the real engine outside it, so a call awaited in the test body
/// never completes. Mock [channelName], for example to act like the native
/// side:
///
/// ```dart
/// tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
///   const MethodChannel(PrivacyService.channelName),
///   // `true` means "done"; isScreenCaptured answers "not captured".
///   (call) async => call.method != 'isScreenCaptured',
/// );
/// ```
///
/// or override [privacyServiceProvider] with a fake. Tests run as Android by
/// default, so a channel mocked as missing makes [copySensitive] return
/// `false`. [dispose] instances you create yourself (the provider does it for
/// you) so that no expiry timer is left pending.
class PrivacyService {
  PrivacyService();

  /// Method channel: `copySensitive`, `clearClipboardIfOurs`,
  /// `clearClipboard`, `setSecureScreen`, `isScreenCaptured`,
  /// `isScreenshotsAllowedBuild`, `systemShowsCopyConfirmation`.
  static const channelName = 'com.vaultapprover.app/privacy';

  /// Event channel: `bool` capture state, or the string `'screenshot'`.
  static const eventChannelName = 'com.vaultapprover.app/privacy/captured';

  static const MethodChannel _channel = MethodChannel(channelName);

  /// One native subscription shared by every instance, because the event
  /// channel has a single message handler per engine.
  static final _PrivacyEventSource _eventSource = _PrivacyEventSource();

  /// Methods the native side answered with [MissingPluginException] (no
  /// channel at all, or a method it does not implement). Later calls to them
  /// go straight to the fallback; the other methods still try native.
  final Set<String> _missingMethods = <String>{};

  /// The last clipboard operation still running, or `null` when idle; see
  /// [_serialized].
  Future<void>? _tail;

  /// Bumped by every copy or clear, so an expiry timer that fires after a
  /// newer call does nothing.
  int _generation = 0;

  /// Text this instance put on the clipboard through the fallback path, kept
  /// until it is cleared or superseded so the timer can tell it is still ours.
  String? _fallbackText;
  Timer? _fallbackTimer;

  /// How many callers currently hold [setSecureScreen] on.
  int _secureScreenHolds = 0;

  bool _disposed = false;

  /// Copies [text] so that it disappears from the clipboard after [ttl], and
  /// returns whether it is on the clipboard now.
  ///
  /// - iOS: stored with `localOnly` (no Universal Clipboard/Handoff) and a
  ///   system `expirationDate`, so it expires even if the app is killed.
  /// - Android: the clip is flagged `IS_SENSITIVE` (Android 13+ hides the
  ///   preview) and cleared after [ttl] only if it is still ours. Android 10+
  ///   cannot read the clipboard from the background, so an expiry that
  ///   happens there is finished when the app regains focus. If the process
  ///   dies first (swiped out of Recents, or killed in the background), the
  ///   clip is cleared at the app's next focus gain instead, and until then
  ///   only Android 13+'s own one-hour auto-clear applies.
  /// - Desktop and web: [Clipboard] plus a Dart timer, which dies with the
  ///   app.
  ///
  /// On iOS and Android a failed native copy returns `false` and leaves the
  /// clipboard alone: the plain [Clipboard] can set neither expiry nor
  /// sensitivity, so the UI should show the failure instead.
  ///
  /// Clipboard calls take effect in call order, so a clear issued right after
  /// a copy (without awaiting it) clears that copy. [ttl] is rounded up to
  /// whole seconds, minimum 1 second. After [dispose] this does nothing and
  /// returns `false`.
  Future<bool> copySensitive(
    String text, {
    Duration ttl = const Duration(seconds: 60),
  }) =>
      _serialized(() async {
        if (_disposed) return false;
        // A new copy supersedes an older fallback copy and its timer.
        _generation++;
        _forgetFallback();
        final ttlSeconds = math.max(1, (ttl.inMilliseconds / 1000).ceil());
        final reply = await _invoke<Object?>('copySensitive', <String, Object>{
          'text': text,
          'ttlSeconds': ttlSeconds,
        });
        if (reply != null) return true;
        if (_disposed || !_mayUsePlainClipboard) return false;
        return _fallbackCopy(text, Duration(seconds: ttlSeconds));
      });

  /// Clears the clipboard now, but only if it still holds the last value
  /// copied by [copySensitive].
  Future<void> clearClipboardIfOurs() => _serialized(() async {
        _generation++;
        await _invoke<Object?>('clearClipboardIfOurs');
        await _fallbackClearIfOurs();
      });

  /// Clears the clipboard unconditionally, e.g. after the user pasted a seed
  /// phrase from it.
  Future<void> clearClipboard() => _serialized(() async {
        _generation++;
        _forgetFallback();
        final reply = await _invoke<Object?>('clearClipboard');
        if (reply != null) return;
        await _setClipboardText('');
      });

  /// Marks a secret-bearing screen. On Android FLAG_SECURE follows the build:
  /// production builds keep it on for the whole app anyway, and builds made
  /// with `-Pallow-screenshots=true` (store screenshots and Maestro only, see
  /// [isScreenshotsAllowedBuild]) keep it off even while held, so every
  /// screen can be captured. iOS cannot block screenshots, so this is a
  /// no-op there; watch [events] instead.
  ///
  /// Calls nest: a screen calls `setSecureScreen(true)` once when it appears
  /// and `setSecureScreen(false)` once when it goes, so overlapping screens
  /// (a tab switch that builds the new tab before disposing the old one)
  /// cannot switch it off under each other. A `false` without a matching
  /// `true` is ignored.
  Future<void> setSecureScreen(bool enabled) async {
    if (enabled) {
      _secureScreenHolds++;
    } else if (_secureScreenHolds > 0) {
      _secureScreenHolds--;
    }
    await _invoke<Object?>('setSecureScreen', <String, Object>{
      'enabled': _secureScreenHolds > 0,
    });
  }

  /// Whether the screen is being recorded, mirrored or AirPlayed right now.
  /// Always `false` on Android and wherever the channel is missing.
  Future<bool> isScreenCaptured() async {
    final reply = await _invoke<bool>('isScreenCaptured');
    return reply?.value ?? false;
  }

  /// Whether this is an Android build made with `-Pallow-screenshots=true`
  /// (`BuildConfig.ALLOW_SCREENSHOTS`), which exists only for store
  /// screenshots and Maestro runs and never sets FLAG_SECURE, not even under
  /// [setSecureScreen]. Always `false` on iOS, in production builds and
  /// wherever the channel is missing or answers anything but a `bool`.
  Future<bool> isScreenshotsAllowedBuild() async {
    final reply = await _invoke<bool>('isScreenshotsAllowedBuild');
    return reply?.value ?? false;
  }

  /// Whether the platform itself confirms every clipboard write on screen:
  /// Android 13+ (API 33) shows its own clipboard overlay, so the app should
  /// not add a "Copied" message of its own there. `false` on iOS, on older
  /// Android and wherever the channel is missing, fails or answers anything
  /// but a `bool`. It cannot change while the app runs, so a real answer is
  /// asked for once.
  Future<bool> systemShowsCopyConfirmation() async {
    final known = _systemShowsCopyConfirmation;
    if (known != null) return known;
    final reply = await _invoke<bool>('systemShowsCopyConfirmation');
    final value = reply?.value;
    if (value != null) _systemShowsCopyConfirmation = value;
    return value ?? false;
  }

  bool? _systemShowsCopyConfirmation;

  /// Capture and screenshot notifications from the platform.
  ///
  /// Every listener shares one native subscription, which starts with the
  /// first listener and stops with the last. On iOS each listener first gets
  /// the current capture state: the first one as soon as the native side
  /// reports it, later ones straight away from the last reported value. It
  /// never emits errors, and it stays silent where the channel is missing.
  Stream<PrivacyEvent> get events => _eventSource.stream;

  /// Stops the fallback expiry timer, and clears a fallback copy that is
  /// still pending, since no timer is left to do it (not awaited). Native
  /// copies keep their platform expiry. Afterwards [copySensitive] does
  /// nothing; the other methods still work.
  ///
  /// [privacyServiceProvider] calls this when its container is disposed.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    if (_fallbackText != null) unawaited(_serialized(_fallbackClearIfOurs));
  }

  /// Maps a raw event-channel value to a [PrivacyEvent]; unknown values give
  /// `null` and are dropped.
  @visibleForTesting
  static PrivacyEvent? decodeEvent(Object? raw) => switch (raw) {
        final bool captured => CaptureChanged(captured),
        'screenshot' => const ScreenshotTaken(),
        _ => null,
      };

  /// Runs [op] once every clipboard operation started before it has
  /// finished, so they take effect in call order.
  ///
  /// When idle, [op] starts synchronously in the caller's zone like a plain
  /// call. (A callback on a future completed in another zone is scheduled in
  /// that zone, which would stall widget tests on their fake clock.)
  Future<T> _serialized<T>(Future<T> Function() op) {
    final previous = _tail;
    final result = previous == null ? op() : previous.then((_) => op());
    final tail = _tail = result.then<void>((_) {}, onError: (Object _) {});
    unawaited(tail.then((_) {
      if (identical(_tail, tail)) _tail = null;
    }));
    return result;
  }

  // ── Native channel ──

  /// Invokes [method] on the native channel. Returns `null` when the channel
  /// is missing or the call failed, so the caller can fall back; otherwise a
  /// [_Reply] wrapping the (possibly `null`) result.
  Future<_Reply<T>?> _invoke<T>(String method, [Object? arguments]) async {
    if (_missingMethods.contains(method)) return null;
    try {
      return _Reply<T>(await _channel.invokeMethod<T>(method, arguments));
    } on MissingPluginException {
      _missingMethods.add(method);
      return null;
    } catch (_) {
      // PlatformException, a result of the wrong type, or no binding yet.
      return null;
    }
  }

  // ── Dart fallback ──

  /// Whether a secret may go to the plain [Clipboard] when the native copy
  /// failed. Not on iOS and Android: that would drop `localOnly`, the system
  /// expiry and `IS_SENSITIVE`, leaving only a timer that dies with the app.
  static bool get _mayUsePlainClipboard =>
      kIsWeb ||
      (defaultTargetPlatform != TargetPlatform.iOS &&
          defaultTargetPlatform != TargetPlatform.android);

  Future<bool> _fallbackCopy(String text, Duration ttl) async {
    if (!await _setClipboardText(text)) return false;
    if (_disposed) {
      // Disposed while writing: no timer may outlive us, so take it back.
      await _setClipboardText('');
      return false;
    }
    _fallbackText = text;
    final generation = _generation;
    _fallbackTimer = Timer(ttl, () {
      unawaited(_serialized(() async {
        // A newer copy or clear that was queued when this fired owns it now.
        if (generation == _generation && !_disposed) {
          await _fallbackClearIfOurs();
        }
      }));
    });
    return true;
  }

  /// Clears the clipboard if we still believe it holds [_fallbackText].
  ///
  /// Where reading the clipboard is silent (desktop Linux/Windows) we check;
  /// elsewhere reading it would show a paste prompt (iOS, macOS, web) or a
  /// "pasted from your clipboard" toast (Android 12+), so we rely on our own
  /// bookkeeping and never call [Clipboard.getData].
  Future<void> _fallbackClearIfOurs() async {
    final text = _fallbackText;
    _forgetFallback();
    if (text == null) return;
    if (_canReadClipboardSilently) {
      try {
        final current = await Clipboard.getData(Clipboard.kTextPlain);
        // Something else was copied since; leave it alone.
        if (current?.text != null && current!.text != text) return;
      } catch (_) {
        // Unreadable: keep believing it is ours.
      }
    }
    await _setClipboardText('');
  }

  void _forgetFallback() {
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    _fallbackText = null;
  }

  static bool get _canReadClipboardSilently {
    if (kIsWeb) return false;
    return switch (defaultTargetPlatform) {
      TargetPlatform.linux ||
      TargetPlatform.windows ||
      TargetPlatform.fuchsia =>
        true,
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.macOS =>
        false,
    };
  }

  static Future<bool> _setClipboardText(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// A successful native reply; [value] may itself be `null`.
class _Reply<T> {
  const _Reply(this.value);

  final T? value;
}

/// Broadcast stream over [PrivacyService.eventChannelName].
///
/// Speaks the same wire protocol as [EventChannel.receiveBroadcastStream],
/// but that one reports a missing native side through [FlutterError], which
/// fails widget tests and spams the console on unsupported platforms. This
/// one swallows it and drops error events.
class _PrivacyEventSource {
  static const MethodCodec _codec = StandardMethodCodec();

  late final StreamController<PrivacyEvent> _controller =
      StreamController<PrivacyEvent>.broadcast(
    onListen: _start,
    onCancel: _stop,
  );

  /// Last capture state the native side reported during the current
  /// subscription; `null` while unknown.
  CaptureChanged? _lastCapture;

  /// [_controller]'s events, preceded for each new listener by
  /// [_lastCapture], so a listener that joins late can still tell the
  /// screen is being captured.
  late final Stream<PrivacyEvent> stream = Stream<PrivacyEvent>.multi(
    (listener) {
      final last = _lastCapture;
      if (last != null) listener.add(last);
      final subscription = _controller.stream.listen(
        listener.add,
        onError: listener.addError,
        onDone: listener.close,
      );
      listener
        ..onPause = subscription.pause
        ..onResume = subscription.resume
        ..onCancel = subscription.cancel;
    },
    isBroadcast: true,
  );

  Future<void> _start() async {
    try {
      ServicesBinding.instance.defaultBinaryMessenger.setMessageHandler(
        PrivacyService.eventChannelName,
        _onMessage,
      );
      await const MethodChannel(
        PrivacyService.eventChannelName,
      ).invokeMethod<void>('listen');
    } catch (_) {
      // No native side: the stream stays silent.
    }
  }

  Future<void> _stop() async {
    // Not observed any more, so the state is unknown until the next start.
    _lastCapture = null;
    try {
      ServicesBinding.instance.defaultBinaryMessenger.setMessageHandler(
        PrivacyService.eventChannelName,
        null,
      );
      await const MethodChannel(
        PrivacyService.eventChannelName,
      ).invokeMethod<void>('cancel');
    } catch (_) {
      // Nothing to stop.
    }
  }

  Future<ByteData?> _onMessage(ByteData? message) async {
    // `null` is end-of-stream; the native side never sends it and the
    // controller is shared, so it is ignored rather than closing the stream.
    if (message == null) return null;
    try {
      final event = PrivacyService.decodeEvent(_codec.decodeEnvelope(message));
      if (event is CaptureChanged) _lastCapture = event;
      if (event != null && !_controller.isClosed) _controller.add(event);
    } catch (_) {
      // Error envelopes and undecodable payloads are dropped.
    }
    return null;
  }
}

/// App-wide [PrivacyService], disposed with its container.
final privacyServiceProvider = Provider<PrivacyService>((ref) {
  final service = PrivacyService();
  ref.onDispose(service.dispose);
  return service;
});
