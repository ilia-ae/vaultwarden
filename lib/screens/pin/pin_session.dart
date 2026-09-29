/// Section-level state of the PIN tab, shared by every tool in it.
///
/// * [pinSessionProvider]: one [PinSession] while the PIN tab is mounted
///   (`autoDispose`: it dies when the tab is left, the app locks or the
///   screen goes away). Owns the seed cache, the wipe signal and the
///   inactivity timer.
/// * [pinSeedProvider]: the session's [PinSeedCache], the 64-byte BIP39 seed
///   shared by PIN 24 and the YubiKey-from-Ledger tool.
/// * [pinToolProvider]: which tool is shown (not sensitive).
/// * [pinComputeRunnerProvider]: where derivations run (`Isolate.run`).
///
/// The session also keeps what must outlive a single tool: the "a pasted
/// secret is still on the clipboard" flag (it survives wipes, so the reminder
/// is back after a background wipe), the YubiKey tool's non-secret settings,
/// PIN 24's imported nickname list, and the open PIN dialogs (a full wipe
/// closes them).
///
/// Nothing here is persisted. Provider values never render their secrets in
/// `toString`, so a `ProviderObserver` cannot log them.
library;

import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pointycastle/digests/sha256.dart';

import 'nickname_backup.dart';
import 'pin24_engine.dart';
import 'yubikey_engine.dart';

/// The tools of the PIN tab, in picker order. [legacyMask] only appears
/// with "Show legacy tools" on.
enum PinTool {
  pin24('pin24'),
  pinShift('shift'),
  yubikey('yubikey'),
  legacyMask('legacy');

  const PinTool(this.id);

  /// Stable id, used in Semantics identifiers (`pin_tool_<id>`).
  final String id;
}

/// Which tool the PIN tab shows. Survives tab switches within a run; not
/// persisted, not secret.
final pinToolProvider = StateProvider<PinTool>((_) => PinTool.pin24);

/// Runs derivations off the UI isolate. Widget tests override it with an
/// inline runner, because their fake clock cannot drive a real isolate.
final pinComputeRunnerProvider = Provider<PinComputeRunner>((_) => _isolateRun);

Future<R> _isolateRun<R>(FutureOr<R> Function() computation) =>
    Isolate.run(computation);

/// The PIN tab's session; see [PinSession].
final pinSessionProvider = Provider.autoDispose<PinSession>((ref) {
  final session = PinSession();
  ref.onDispose(session.dispose);
  return session;
});

/// The shared seed cache of the current [PinSession].
final pinSeedProvider = Provider.autoDispose<PinSeedCache>(
  (ref) => ref.watch(pinSessionProvider).seed,
);

/// What a wipe clears.
enum PinWipeScope {
  /// Seed phrase, passphrase, cached seed and reveal toggles only (🧹).
  seed,

  /// Every input and output of every tool (🚨, background, inactivity).
  all,
}

/// Why a wipe happened (drives the SnackBar that explains it and whether the
/// clipboard is cleaned up).
enum PinWipeReason {
  /// 🧹 / 🚨 buttons.
  user,

  /// The app went to the background.
  background,

  /// 120 s without interaction.
  inactivity,

  /// "Wipe" on the screenshot warning.
  screenshot,

  /// The PIN tab was left (swipe or tab bar).
  left,
}

/// One wipe, delivered to every listener of [PinSession.wipes].
@immutable
class PinWipeEvent {
  const PinWipeEvent({
    required this.serial,
    required this.scope,
    required this.reason,
    required this.hadContent,
  });

  /// Increases with every wipe, so two identical wipes are still distinct.
  final int serial;
  final PinWipeScope scope;
  final PinWipeReason reason;

  /// Whether anything (input, output or cached seed) was cleared.
  final bool hadContent;

  @override
  String toString() => 'PinWipeEvent($serial, $scope, $reason)';
}

/// State shared by the tools of the PIN tab for as long as it is mounted.
///
/// Tools:
/// * listen to [wipes] and clear their inputs/outputs on every event
///   ([PinWipeScope.seed] clears only the seed phrase and passphrase);
/// * call [touch] on every edit, so the inactivity timer restarts;
/// * register a [registerContentProbe] so a wipe knows whether anything was
///   actually cleared.
class PinSession {
  PinSession({this.inactivityTimeout = const Duration(seconds: 120)});

  /// Idle time after which everything is wiped. Independent of the app's
  /// lock timeout (which can be "never") and of demo mode.
  final Duration inactivityTimeout;

  /// The 64-byte BIP39 seed, cached between derivations.
  final PinSeedCache seed = PinSeedCache();

  final ValueNotifier<PinWipeEvent?> _wipes = ValueNotifier<PinWipeEvent?>(
    null,
  );
  final List<bool Function()> _probes = [];
  final List<bool Function()> _unsavedProbes = [];
  final List<VoidCallback> _dialogClosers = [];
  Timer? _idle;
  int _serial = 0;
  bool _disposed = false;

  /// A paste put a secret (seed phrase, passphrase, master key) on the
  /// system clipboard, which still holds it. Survives wipes: only clearing
  /// the clipboard resets it.
  final ValueNotifier<bool> clipboardHoldsPaste = ValueNotifier<bool>(false);

  /// The YubiKey tool's settings (no secrets), kept across tool switches.
  final YkSettings yk = YkSettings();

  /// Nicknames and charsets imported into PIN 24 from a Ledger Passwords
  /// backup. Not secret, but they tell which services someone uses: kept
  /// only here, in memory, and dropped by every full wipe and on dispose.
  NicknameBackup? nicknameBackup;

  /// Set when a tool sent the user to PIN 24 to enter the seed; PIN 24 then
  /// scrolls to the seed field and offers a way back.
  PinTool? returnTo;

  /// Clipboard cleanup for a user-initiated wipe or Clear, installed by the
  /// section (which owns the privacy channel).
  Future<void> Function()? onUserCleanup;

  /// The last wipe; listeners are notified on every new one.
  ValueListenable<PinWipeEvent?> get wipes => _wipes;

  /// Restarts the inactivity timer. Call on every user interaction.
  void touch() {
    if (_disposed) return;
    _idle?.cancel();
    _idle = Timer(inactivityTimeout, () {
      _idle = null;
      wipe(reason: PinWipeReason.inactivity);
    });
  }

  /// Registers a callback telling whether a tool holds anything to wipe.
  /// Returns the function that unregisters it.
  VoidCallback registerContentProbe(bool Function() hasContent) {
    _probes.add(hasContent);
    return () => _probes.remove(hasContent);
  }

  /// Whether any tool holds input/output, a seed is cached or a nickname
  /// list is loaded.
  bool get hasContent =>
      seed.hasSeed || nicknameBackup != null || _probes.any((p) => p());

  /// Registers a callback telling whether a tool holds values that exist
  /// nowhere else (YubiKey random values), so leaving it asks first.
  VoidCallback registerUnsavedProbe(bool Function() hasUnsaved) {
    _unsavedProbes.add(hasUnsaved);
    return () => _unsavedProbes.remove(hasUnsaved);
  }

  /// Whether leaving the current tool would lose values that exist nowhere
  /// else.
  bool get hasUnsavedValues => _unsavedProbes.any((p) => p());

  /// Registers [close], which dismisses an open PIN dialog; every
  /// [PinWipeScope.all] wipe calls it, so no dialog outlives the values it
  /// is about. Returns the function that unregisters it.
  VoidCallback registerDialog(VoidCallback close) {
    _dialogClosers.add(close);
    return () => _dialogClosers.remove(close);
  }

  /// Marks that a paste put a secret on the clipboard.
  void markPasted() {
    if (!_disposed) clipboardHoldsPaste.value = true;
  }

  /// Runs the clipboard cleanup of a user-initiated Clear (not awaited).
  void userCleared() {
    if (_disposed) return;
    final cleanup = onUserCleanup;
    if (cleanup != null) unawaited(cleanup());
  }

  /// Zeroes the cached seed and tells every tool to clear itself.
  void wipe(
      {PinWipeScope scope = PinWipeScope.all, required PinWipeReason reason}) {
    if (_disposed) return;
    final hadContent = hasContent;
    seed.wipe();
    if (scope == PinWipeScope.all) {
      yk.serials = '';
      returnTo = null;
      nicknameBackup = null;
      for (final close in List.of(_dialogClosers)) {
        close();
      }
    }
    _wipes.value = PinWipeEvent(
      serial: ++_serial,
      scope: scope,
      reason: reason,
      hadContent: hadContent,
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _idle?.cancel();
    _idle = null;
    _probes.clear();
    _unsavedProbes.clear();
    _dialogClosers.clear();
    onUserCleanup = null;
    nicknameBackup = null;
    seed.wipe();
    seed.dispose();
    _wipes.dispose();
    clipboardHoldsPaste.dispose();
  }

  @override
  String toString() => 'PinSession(${seed.hasSeed ? 'seed cached' : 'empty'})';
}

/// The derived 64-byte BIP39 seed plus a digest of the (canonical phrase,
/// passphrase) it came from, so PBKDF2 (2048 × HMAC-SHA512) runs once per
/// phrase instead of on every nickname or length change.
///
/// Both buffers are zeroed on [wipe], on replacement and on dispose. Callers
/// get copies and must zero them after use.
class PinSeedCache extends ChangeNotifier {
  Uint8List? _key;
  Uint8List? _seed;
  int _wordCount = 0;

  bool get hasSeed => _seed != null;

  /// Words of the phrase the cached seed came from (0 when empty).
  int get wordCount => _wordCount;

  /// Cache key for a phrase + passphrase: SHA-256 over their UTF-16 code
  /// units (lossless even for lone surrogates), length-prefixed.
  static Uint8List keyFor(String canonicalPhrase, String passphrase) {
    final a = canonicalPhrase.codeUnits;
    final b = passphrase.codeUnits;
    final buf = Uint8List(4 + 2 * a.length + 2 * b.length);
    final view = ByteData.sublistView(buf)..setUint32(0, a.length);
    var o = 4;
    for (final c in a) {
      view.setUint16(o, c);
      o += 2;
    }
    for (final c in b) {
      view.setUint16(o, c);
      o += 2;
    }
    final digest = SHA256Digest().process(buf);
    buf.fillRange(0, buf.length, 0);
    return digest;
  }

  /// A copy of the cached seed if it was derived from [key]'s phrase and
  /// passphrase, else `null`.
  Uint8List? lookup(Uint8List key) {
    final seed = _seed;
    final own = _key;
    if (seed == null || own == null || !_sameBytes(own, key)) return null;
    return Uint8List.fromList(seed);
  }

  /// A copy of whatever seed is cached (for a tool that reuses the seed
  /// entered in PIN 24), or `null`.
  Uint8List? copySeed() {
    final seed = _seed;
    return seed == null ? null : Uint8List.fromList(seed);
  }

  /// Takes ownership of [seed] and [key]; the previous ones are zeroed.
  void store(Uint8List key, Uint8List seed, {required int wordCount}) {
    _zero();
    _key = key;
    _seed = seed;
    _wordCount = wordCount;
    notifyListeners();
  }

  /// Zeroes and drops the cached seed.
  void wipe() {
    final had = _seed != null;
    _zero();
    if (had) notifyListeners();
  }

  void _zero() {
    _key?.fillRange(0, _key!.length, 0);
    _seed?.fillRange(0, _seed!.length, 0);
    _key = null;
    _seed = null;
    _wordCount = 0;
  }

  @override
  void dispose() {
    _zero();
    super.dispose();
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  @override
  String toString() => 'PinSeedCache(${hasSeed ? 'seed' : 'empty'})';
}
