import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// OAuth **Web client** ID that Firebase auto-creates when the Google
/// sign-in provider is enabled in the console. google_sign_in (v7) needs it
/// as `serverClientId` on Android to mint an ID token Firebase will accept.
///
/// Filled in after the Google provider is enabled — it appears as the
/// `client_type: 3` entry in a freshly downloaded google-services.json, or
/// as the "Web SDK configuration" client ID in the console. Overridable at
/// build time via --dart-define=GOOGLE_SERVER_CLIENT_ID=... as well.
const String googleServerClientId = String.fromEnvironment(
  'GOOGLE_SERVER_CLIENT_ID',
  defaultValue:
      '1048656681718-5178cabf62pgcu7d86v4u8516npdvbsj.apps.googleusercontent.com',
);

/// User-facing auth failure with a message safe to show.
class AuthException implements Exception {
  AuthException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Thin wrapper over Firebase Auth for the cloud-sync identity.
/// Google + Apple sign-in both resolve to a Firebase [User].
class AuthService {
  AuthService(this._auth);

  final FirebaseAuth _auth;
  bool _googleInitialized = false;

  User? get currentUser => _auth.currentUser;
  Stream<User?> authStateChanges() => _auth.authStateChanges();

  Future<void> _ensureGoogleInitialized() async {
    if (_googleInitialized) return;
    await GoogleSignIn.instance.initialize(
      serverClientId:
          googleServerClientId.isEmpty ? null : googleServerClientId,
    );
    _googleInitialized = true;
  }

  /// Sign in with Google → Firebase. Throws [AuthException] on cancel/failure.
  Future<User> signInWithGoogle() async {
    if (googleServerClientId.isEmpty) {
      throw AuthException(
        'Google sign-in is not configured yet. Enable the Google provider in '
        'Firebase and set the web client ID.',
      );
    }
    await _ensureGoogleInitialized();
    final signIn = GoogleSignIn.instance;
    if (!signIn.supportsAuthenticate()) {
      throw AuthException('Google sign-in is not supported on this platform.');
    }

    final GoogleSignInAccount account;
    try {
      account = await signIn.authenticate();
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        throw AuthException('Sign-in cancelled.');
      }
      throw AuthException('Google sign-in failed: ${e.description ?? e.code}');
    }

    final idToken = account.authentication.idToken;
    if (idToken == null) {
      throw AuthException('Google did not return an ID token.');
    }
    final credential = GoogleAuthProvider.credential(idToken: idToken);
    return _authorize(credential, provider: 'Google');
  }

  /// Sign in with (or link) [credential].
  ///
  /// If a user is already signed in, the new provider is LINKED to that same
  /// account so the uid — and therefore the synced settings document — stays
  /// the one and only. This also sidesteps `account-exists-with-different-
  /// credential`: with Firebase's default one-account-per-email policy, a
  /// second provider on the same email cannot create a separate account.
  Future<User> _authorize(AuthCredential credential,
      {required String provider}) async {
    final current = _auth.currentUser;
    if (current != null) {
      try {
        final result = await current.linkWithCredential(credential);
        debugPrint('[$provider] linked to uid=${result.user?.uid}');
        return result.user!;
      } on FirebaseAuthException catch (e) {
        debugPrint('[$provider] link failed code=${e.code} — trying sign-in');
        if (e.code != 'provider-already-linked' &&
            e.code != 'credential-already-in-use') {
          throw AuthException('$provider sign-in failed (Firebase: ${e.code})');
        }
        // Fall through: the provider identity already belongs to an account —
        // sign in with it instead of linking.
      }
    }
    try {
      final result = await _auth.signInWithCredential(credential);
      debugPrint('[$provider] Firebase OK uid=${result.user?.uid}');
      return result.user!;
    } on FirebaseAuthException catch (e, st) {
      debugPrint('[$provider] FirebaseAuthException code=${e.code} '
          'message=${e.message}\n$st');
      if (e.code == 'account-exists-with-different-credential') {
        throw AuthException(
          'This email is already used with a different sign-in method. '
          'Sign in with that method first, then connect $provider.',
        );
      }
      throw AuthException('$provider sign-in failed (Firebase: ${e.code})');
    }
  }

  /// Sign in with (or link) Apple via FlutterFire's built-in provider flow.
  ///
  /// `signInWithProvider`/`linkWithProvider` let the Firebase SDK run the
  /// native ASAuthorization sheet AND manage the nonce internally. The manual
  /// sign_in_with_apple + hashed-nonce dance intermittently fails Firebase
  /// validation with `invalid-credential` (firebase-ios-sdk #15571), which is
  /// exactly what we hit on-device.
  Future<User> signInWithApple() async {
    final provider = AppleAuthProvider()
      ..addScope('email')
      ..addScope('name');
    final current = _auth.currentUser;
    try {
      // Signed in already → LINK Apple to the same uid (same settings doc).
      final result = current != null
          ? await current.linkWithProvider(provider)
          : await _auth.signInWithProvider(provider);
      debugPrint('[Apple] OK uid=${result.user?.uid} '
          '(${current != null ? 'linked' : 'signed in'})');
      return result.user!;
    } on FirebaseAuthException catch (e, st) {
      debugPrint('[Apple] FirebaseAuthException code=${e.code} '
          'message=${e.message}\n$st');
      if (e.code == 'provider-already-linked' ||
          e.code == 'credential-already-in-use') {
        // Apple identity already belongs to an account — sign in with it.
        final result = await _auth.signInWithProvider(provider);
        return result.user!;
      }
      if (e.code == 'canceled' ||
          e.code == 'user-cancelled' ||
          e.code == 'web-context-canceled') {
        throw AuthException('Sign-in cancelled.');
      }
      if (e.code == 'account-exists-with-different-credential') {
        throw AuthException(
          'This email is already used with a different sign-in method. '
          'Sign in with that method first, then connect Apple.',
        );
      }
      throw AuthException('Apple sign-in failed (Firebase: ${e.code})');
    }
  }

  /// Sign out of Firebase (and Google, if used). Does not affect the Vault
  /// session or on-device keys — only the cloud-sync identity.
  Future<void> signOut() async {
    if (_googleInitialized) {
      try {
        await GoogleSignIn.instance.signOut();
      } catch (_) {/* best effort */}
    }
    await _auth.signOut();
  }
}
