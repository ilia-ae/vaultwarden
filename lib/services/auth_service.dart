import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'auth_exception.dart';

export 'auth_exception.dart';

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
  Future<User> signInWithGoogle() async =>
      _authorize(await googleCredential(), provider: 'Google');

  /// A Firebase credential from the native Google sheet. Throws
  /// [AuthException] on cancel/failure.
  @protected
  Future<AuthCredential> googleCredential() async {
    if (googleServerClientId.isEmpty) {
      throw AuthException(AuthFailure.notConfigured, provider: 'Google');
    }
    await _ensureGoogleInitialized();
    final signIn = GoogleSignIn.instance;
    if (!signIn.supportsAuthenticate()) {
      throw AuthException(AuthFailure.unsupported, provider: 'Google');
    }

    final GoogleSignInAccount account;
    try {
      account = await signIn.authenticate();
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        throw AuthException(AuthFailure.cancelled, provider: 'Google');
      }
      throw AuthException(
        AuthFailure.failed,
        provider: 'Google',
        detail: e.code.name,
        message: 'Google sign-in failed: ${e.description ?? e.code}',
      );
    }

    final idToken = account.authentication.idToken;
    if (idToken == null) {
      throw AuthException(AuthFailure.missingToken, provider: 'Google');
    }
    return GoogleAuthProvider.credential(idToken: idToken);
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
          throw AuthException(
            AuthFailure.failed,
            provider: provider,
            detail: e.code,
          );
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
        throw AuthException(AuthFailure.emailInUse, provider: provider);
      }
      throw AuthException(
        AuthFailure.failed,
        provider: provider,
        detail: e.code,
      );
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
    final provider = _appleProvider();
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
      if (_appleCancelCodes.contains(e.code)) {
        throw AuthException(AuthFailure.cancelled, provider: 'Apple');
      }
      if (e.code == 'account-exists-with-different-credential') {
        throw AuthException(AuthFailure.emailInUse, provider: 'Apple');
      }
      throw AuthException(
        AuthFailure.failed,
        provider: 'Apple',
        detail: e.code,
      );
    }
  }

  static AppleAuthProvider _appleProvider() => AppleAuthProvider()
    ..addScope('email')
    ..addScope('name');

  /// Codes Firebase reports when the user closes the Apple sheet.
  static const _appleCancelCodes = {
    'canceled',
    'user-cancelled',
    'web-context-canceled',
  };

  /// Deletes the cloud-sync account (App Store guideline 5.1.1(v)).
  ///
  /// 1. Confirms the identity again: Firebase deletes only a user who signed
  ///    in recently, and Apple's sheet also returns the authorization code
  ///    that revokes the Sign in with Apple token. Apple is used when it is
  ///    linked and this is an Apple platform (or Google is not linked);
  ///    otherwise Google.
  /// 2. Runs [deleteData] for the user's synced data (while still signed in,
  ///    so the Firestore rules let the owner delete it).
  /// 3. Revokes the Apple token (best effort: it needs the Apple provider's
  ///    OAuth code-flow keys in the Firebase console).
  /// 4. Deletes the Firebase user, then drops the app's Google grant (best
  ///    effort).
  ///
  /// Throws [AuthException]; nothing is deleted when the confirmation is
  /// cancelled or fails. Does not touch the vault session or on-device keys.
  Future<void> deleteAccount({
    required Future<void> Function(String uid) deleteData,
  }) async {
    final user = _auth.currentUser;
    if (user == null) return;
    final providers = {for (final p in user.providerData) p.providerId};
    final hasGoogle = providers.contains('google.com');
    final useApple = providers.contains('apple.com') &&
        (!hasGoogle ||
            defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS);
    final provider = useApple ? 'Apple' : 'Google';

    String? appleCode;
    try {
      if (useApple) {
        final result = await user.reauthenticateWithProvider(_appleProvider());
        appleCode = result.additionalUserInfo?.authorizationCode;
      } else if (hasGoogle) {
        await user.reauthenticateWithCredential(await googleCredential());
      }
    } on FirebaseAuthException catch (e) {
      debugPrint('[$provider] re-auth for deletion failed code=${e.code}');
      if (_appleCancelCodes.contains(e.code)) {
        throw AuthException(AuthFailure.cancelled, provider: provider);
      }
      if (e.code == 'user-mismatch') {
        throw AuthException(AuthFailure.wrongAccount, provider: provider);
      }
      throw AuthException(AuthFailure.failed,
          provider: provider, detail: e.code);
    }

    try {
      await deleteData(user.uid);
      if (appleCode != null && appleCode.isNotEmpty) {
        try {
          await _auth.revokeTokenWithAuthorizationCode(appleCode);
        } catch (e) {
          debugPrint('[Apple] token revoke failed: $e');
        }
      }
      await user.delete();
    } on FirebaseException catch (e) {
      debugPrint('[$provider] account deletion failed code=${e.code}');
      if (e.code != 'user-not-found') {
        throw AuthException(AuthFailure.deleteFailed,
            provider: provider, detail: e.code);
      }
      // Already gone on the server: just drop the local sign-in.
      await _auth.signOut();
    }

    if (hasGoogle) await disconnectGoogle();
  }

  /// Revokes the app's Google grant on this device (best effort: the Google
  /// SDK only knows an account that signed in here).
  @protected
  Future<void> disconnectGoogle() async {
    try {
      await _ensureGoogleInitialized();
      await GoogleSignIn.instance.disconnect();
    } catch (e) {
      debugPrint('[Google] disconnect failed: $e');
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
