import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

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
    final result = await _auth.signInWithCredential(credential);
    return result.user!;
  }

  /// Sign in with Apple → Firebase. Uses a hashed nonce to prevent replay.
  /// Requires the Apple provider configured (Apple Developer + Firebase).
  Future<User> signInWithApple() async {
    final rawNonce = _randomNonce();
    final hashedNonce = _sha256Hex(rawNonce);

    final AuthorizationCredentialAppleID appleCredential;
    try {
      appleCredential = await SignInWithApple.getAppleIDCredential(
        scopes: const [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        nonce: hashedNonce,
      );
    } on SignInWithAppleAuthorizationException catch (e, st) {
      debugPrint('[AppleSignIn] AuthorizationException code=${e.code} '
          'message=${e.message}\n$st');
      if (e.code == AuthorizationErrorCode.canceled) {
        throw AuthException('Sign-in cancelled.');
      }
      throw AuthException('Apple sign-in failed: ${e.message}');
    } catch (e, st) {
      debugPrint('[AppleSignIn] getAppleIDCredential unexpected: $e\n$st');
      rethrow;
    }

    final idToken = appleCredential.identityToken;
    debugPrint('[AppleSignIn] credential OK; idToken=${idToken != null}, '
        'authCode=${appleCredential.authorizationCode.isNotEmpty}');
    if (idToken == null) {
      throw AuthException('Apple did not return an identity token.');
    }
    final oauth = OAuthProvider('apple.com').credential(
      idToken: idToken,
      rawNonce: rawNonce,
    );
    try {
      final result = await _auth.signInWithCredential(oauth);
      debugPrint('[AppleSignIn] Firebase OK uid=${result.user?.uid}');
      return result.user!;
    } on FirebaseAuthException catch (e, st) {
      debugPrint('[AppleSignIn] FirebaseAuthException code=${e.code} '
          'message=${e.message}\n$st');
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

  static String _randomNonce([int length = 32]) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._';
    final rng = Random.secure();
    return List.generate(length, (_) => chars[rng.nextInt(chars.length)])
        .join();
  }

  static String _sha256Hex(String input) {
    final digest =
        SHA256Digest().process(Uint8List.fromList(utf8.encode(input)));
    return digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
