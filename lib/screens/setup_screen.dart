import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../app.dart';
import '../demo_fixtures.dart';
import '../glass.dart';
import '../l10n/app_localizations.dart';
import '../models/server_environment.dart';
import '../providers/service_providers.dart';
import '../providers/session_provider.dart';
import '../services/vault_api.dart';
import '../utils/error_formatter.dart';
import '../widgets/client_cert_section.dart';
import '../widgets/control_id.dart';
import '../widgets/login_dialogs.dart';
import '../widgets/server_selector.dart';

/// Inputs of one login attempt. Snapshotted when the user taps "Set Up", so
/// the 2FA / new-device retries always repeat the same request.
class _LoginAttempt {
  const _LoginAttempt({
    required this.serverUrl,
    required this.email,
    required this.password,
    this.twoFactorToken,
    this.twoFactorProvider,
    this.rememberTwoFactor = true,
    this.newDeviceOtp,
  });

  final String serverUrl;
  final String email;
  final String password;
  final String? twoFactorToken;
  final int? twoFactorProvider;
  final bool rememberTwoFactor;
  final String? newDeviceOtp;

  _LoginAttempt withTwoFactor(String token, int provider, bool remember) =>
      _LoginAttempt(
        serverUrl: serverUrl,
        email: email,
        password: password,
        twoFactorToken: token,
        twoFactorProvider: provider,
        rememberTwoFactor: remember,
        newDeviceOtp: newDeviceOtp,
      );

  _LoginAttempt withNewDeviceOtp(String otp) => _LoginAttempt(
        serverUrl: serverUrl,
        email: email,
        password: password,
        twoFactorToken: twoFactorToken,
        twoFactorProvider: twoFactorProvider,
        rememberTwoFactor: rememberTwoFactor,
        newDeviceOtp: otp,
      );
}

class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key});

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _serverUrlController = TextEditingController(text: 'https://');
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  /// Bitwarden cloud (US/EU) or a self-hosted URL (F16).
  ServerRegion _region = ServerRegion.selfHosted;

  bool _isLoading = false;
  SetupStep? _step;
  String? _statusMessage;
  bool _obscurePassword = true;
  bool _demoTotpShown = false;

  /// The server demanded (or rejected) a client certificate (F1).
  bool _certHighlight = false;

  /// Server URL handed to the certificate row, debounced while typing.
  String _certUrl = '';
  Timer? _certUrlDebounce;

  // Build-version footer + hidden 5-tap demo gesture (for testers).
  String _appVersion = '';
  int _demoTapCount = 0;
  DateTime? _lastDemoTap;

  AppLocalizations get _l => AppLocalizations.of(context)!;

  @override
  void initState() {
    super.initState();
    _certUrl = _serverUrlController.text;
    _serverUrlController.addListener(_onServerUrlChanged);
    _loadVersion();
    if (demoMode == 'totp') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_demoTotpShown) {
          _demoTotpShown = true;
          _showDemoTotpDialog();
        }
      });
    }
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() => _appVersion = 'v${info.version} (${info.buildNumber})');
      }
    } catch (_) {
      // Version is a nicety — never block the setup screen on it.
    }
  }

  /// Tap the version 5× (within 2s between taps) to drop into demo mode.
  void _onVersionTap() {
    final now = DateTime.now();
    if (_lastDemoTap == null ||
        now.difference(_lastDemoTap!) > const Duration(seconds: 2)) {
      _demoTapCount = 0;
    }
    _lastDemoTap = now;
    _demoTapCount++;
    if (_demoTapCount >= 3 && _demoTapCount < 5) {
      HapticFeedback.selectionClick(); // subtle "keep going" feedback
    }
    if (_demoTapCount >= 5) {
      _demoTapCount = 0;
      _activateDemo();
    }
  }

  void _activateDemo() {
    HapticFeedback.mediumImpact();
    // Stops and forgets everything real (storage untouched), then the App
    // moves the whole UI into the demo's own provider container — which
    // starts unlocked on fixtures and shows the "demo mode" notice (F7).
    ref.read(sessionProvider.notifier).enterRuntimeDemo();
  }

  void _onServerUrlChanged() {
    if (_certHighlight) setState(() => _certHighlight = false);
    _certUrlDebounce?.cancel();
    _certUrlDebounce = Timer(const Duration(milliseconds: 400), () {
      if (mounted && _certUrl != _serverUrlController.text) {
        setState(() => _certUrl = _serverUrlController.text);
      }
    });
  }

  @override
  void dispose() {
    _certUrlDebounce?.cancel();
    _serverUrlController.removeListener(_onServerUrlChanged);
    _serverUrlController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  /// The server URL for the selected region.
  String get _serverUrl => switch (_region) {
        ServerRegion.us => ServerEnvironment.us.baseUrl,
        ServerRegion.eu => ServerEnvironment.eu.baseUrl,
        ServerRegion.selfHosted => _serverUrlController.text.trim(),
      };

  // ── Login flow ──

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    // Screenshot builds (DEMO_MODE=setup/totp) show this screen with the
    // real providers: never reach a server or the keychain from there.
    if (demoActive) return;
    final invalid = _formKey.currentState!.validateGranularly();
    if (invalid.isNotEmpty) {
      _revealFirstError(invalid);
      return;
    }
    if (!await _confirmPlainHttp()) return;
    if (!await _ensureBiometrics()) return;
    if (!mounted) return;
    await _attemptLogin(_LoginAttempt(
      serverUrl: _serverUrl,
      email: _emailController.text.trim(),
      password: _passwordController.text,
    ));
  }

  /// The Set Up button is pinned under the scrolling form, so a field with
  /// an error may be scrolled out of view: bring the topmost one back.
  void _revealFirstError(Set<FormFieldState<Object?>> invalid) {
    double top(FormFieldState<Object?> field) {
      final box = field.context.findRenderObject();
      return box is RenderBox && box.attached
          ? box.localToGlobal(Offset.zero).dy
          : double.infinity;
    }

    final first = invalid.reduce((a, b) => top(a) <= top(b) ? a : b);
    unawaited(Scrollable.ensureVisible(
      first.context,
      alignment: 0.2,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 350),
      curve: appSpring,
    ));
  }

  /// `http://` to anything but this device sends the master-password hash,
  /// tokens and approvals in the clear: sign in only after a warning.
  Future<bool> _confirmPlainHttp() async {
    if (_region != ServerRegion.selfHosted) return true;
    try {
      if (!ServerEnvironment.isPlaintextRemote(_serverUrl)) return true;
    } on FormatException {
      return true; // the validator already reported it
    }
    final l = _l;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.no_encryption_outlined,
            color: Theme.of(ctx).colorScheme.error),
        title: Text(l.plainHttpTitle),
        content: Text(l.plainHttpMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l.cancel),
          ),
          ControlId(
            'btn_plain_http_continue',
            child: TextButton(
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(ctx).colorScheme.error,
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l.plainHttpContinue),
            ),
          ),
        ],
      ),
    );
    return proceed == true && mounted;
  }

  /// The app stores the keys behind biometrics: refuse to set up without.
  Future<bool> _ensureBiometrics() async {
    final biometric = ref.read(biometricServiceProvider);
    while (mounted) {
      final available = await biometric.isAvailable();
      if (available) return true;
      if (!mounted) return false;
      final l = _l;
      final retry = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: Text(l.biometricRequiredTitle),
          content: Text(l.biometricRequiredMessage),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l.biometricRetry),
            ),
          ],
        ),
      );
      if (retry != true) return false;
    }
    return false;
  }

  void _setLoading(bool loading, {String? status}) {
    if (!mounted) return;
    setState(() {
      _isLoading = loading;
      _statusMessage = status;
      if (!loading) _step = null;
    });
  }

  /// One password grant with [attempt]. Success replaces this screen (the
  /// App follows the session). Throws the typed server errors.
  Future<void> _runSetup(_LoginAttempt attempt) async {
    await ref.read(sessionProvider.notifier).setup(
          serverUrl: attempt.serverUrl,
          email: attempt.email,
          masterPassword: attempt.password,
          onProgress: (_) {},
          onStep: (step) {
            if (mounted) setState(() => _step = step);
          },
          twoFactorToken: attempt.twoFactorToken,
          twoFactorProvider: attempt.twoFactorProvider,
          rememberTwoFactor: attempt.rememberTwoFactor,
          newDeviceOtp: attempt.newDeviceOtp,
        );
  }

  Future<void> _attemptLogin(_LoginAttempt attempt) async {
    _setLoading(true);
    try {
      await _runSetup(attempt);
    } on TwoFactorRequiredException catch (e) {
      _setLoading(false);
      await _twoFactorFlow(e, attempt);
    } on NewDeviceVerificationRequiredException {
      _setLoading(false);
      await _newDeviceFlow(attempt);
    } catch (e) {
      _setLoading(false);
      _cancelPendingLogin();
      _showLoginError(e);
    }
  }

  void _cancelPendingLogin() {
    if (!mounted) return;
    ref.read(sessionProvider.notifier).cancelPendingLogin();
  }

  void _noteCertificateError(Object e) {
    if (isClientCertificateError(e) &&
        _region == ServerRegion.selfHosted &&
        mounted) {
      setState(() => _certHighlight = true);
    }
  }

  void _showLoginError(Object e) {
    if (!mounted) return;
    _noteCertificateError(e);
    _showError(formatError(e, _l));
  }

  /// Submits a code from the 2FA / new-device dialog. Wrong codes stay in
  /// the dialog (A3/A4); a different server demand closes it.
  Future<CodeSubmitResult> _submitCode(
    _LoginAttempt attempt, {
    required bool newDevice,
  }) async {
    final l = _l;
    try {
      await _runSetup(attempt);
      return const CodeAccepted();
    } on InvalidTwoFactorCodeException catch (e) {
      return CodeRejected(formatError(e, l));
    } on InvalidNewDeviceOtpException catch (e) {
      return CodeRejected(formatError(e, l));
    } on NewDeviceVerificationRequiredException catch (e) {
      if (newDevice) return CodeRejected(formatError(e, l));
      return CodeFlowChanged(e);
    } on TwoFactorRequiredException catch (e) {
      // After a 2FA code this means the code/provider was not accepted.
      if (!newDevice) {
        final m = e.serverMessage;
        return CodeRejected(
            m == null || m.toLowerCase() == 'two factor required.'
                ? l.errorInvalidTwoFactorCode
                : m);
      }
      return CodeFlowChanged(e);
    } catch (e) {
      _noteCertificateError(e);
      return CodeRejected(formatError(e, l));
    } finally {
      if (mounted) setState(() => _step = null);
    }
  }

  /// POST send-email-login (F12): null on success, else the error text.
  Future<String?> _sendEmailCode(_LoginAttempt attempt) async {
    final l = _l;
    try {
      await ref.read(sessionProvider.notifier).sendEmailLoginCode(
            serverUrl: attempt.serverUrl,
            email: attempt.email,
            masterPassword: attempt.password,
          );
      return null;
    } catch (e) {
      return formatError(e, l);
    }
  }

  Future<String?> _resendNewDeviceOtp(_LoginAttempt attempt) async {
    final l = _l;
    try {
      await ref.read(sessionProvider.notifier).resendNewDeviceOtp(
            serverUrl: attempt.serverUrl,
            email: attempt.email,
            masterPassword: attempt.password,
          );
      return null;
    } catch (e) {
      return formatError(e, l);
    }
  }

  /// Provider picker → (e-mail: send code) → code dialog (F12, A4, A6).
  Future<void> _twoFactorFlow(
    TwoFactorRequiredException e,
    _LoginAttempt base,
  ) async {
    final choices = TwoFactorProvider.choices(e.availableProviders);
    int? provider = TwoFactorProvider.automaticChoice(choices);
    while (true) {
      if (!mounted) return;
      provider ??= await showTwoFactorProviderPicker(
        context,
        choices: choices,
        obscuredEmail: e.obscuredEmail,
      );
      if (!mounted) return;
      if (provider == null) {
        _cancelPendingLogin();
        return;
      }
      final chosen = provider;
      final l = _l;

      String? initialError;
      String? initialInfo;
      if (chosen == TwoFactorProvider.email) {
        _setLoading(true, status: l.sendingCode);
        initialError = await _sendEmailCode(base);
        _setLoading(false);
        if (!mounted) return;
        if (initialError == null) {
          final to = e.obscuredEmail;
          initialInfo = to == null ? l.codeSent : l.codeSentTo(to);
        }
      }

      var last = base;
      final result = await showVerificationCodeDialog(
        context,
        kind: switch (chosen) {
          TwoFactorProvider.email => VerificationCodeKind.email,
          TwoFactorProvider.yubiKey => VerificationCodeKind.yubiKey,
          TwoFactorProvider.recoveryCode => VerificationCodeKind.recoveryCode,
          _ => VerificationCodeKind.totp,
        },
        title: twoFactorProviderName(chosen, l),
        message: switch (chosen) {
          TwoFactorProvider.email => e.obscuredEmail == null
              ? l.twoFactorPromptEmail
              : l.twoFactorPromptEmailTo(e.obscuredEmail!),
          TwoFactorProvider.yubiKey => l.twoFactorPromptYubiKey,
          TwoFactorProvider.recoveryCode => l.twoFactorPromptRecoveryCode,
          _ => l.twoFactorPrompt,
        },
        showRemember: chosen != TwoFactorProvider.recoveryCode,
        offerAnotherMethod: choices.length > 1,
        initialError: initialError,
        initialInfo: initialInfo,
        onResend: chosen == TwoFactorProvider.email
            ? () => _sendEmailCode(base)
            : null,
        onSubmit: (code, remember) {
          last = base.withTwoFactor(code, chosen, remember);
          return _submitCode(last, newDevice: false);
        },
      );
      if (!mounted) return;
      switch (result.outcome) {
        case VerificationDialogOutcome.accepted:
          return;
        case VerificationDialogOutcome.cancelled:
          _cancelPendingLogin();
          return;
        case VerificationDialogOutcome.anotherMethod:
          provider = null;
        case VerificationDialogOutcome.flowChanged:
          final error = result.error;
          if (error is NewDeviceVerificationRequiredException) {
            await _newDeviceFlow(last);
          } else if (error != null) {
            _showLoginError(error);
          }
          return;
      }
    }
  }

  /// bitwarden.com new-device verification (F6): the e-mailed code is sent
  /// back with the same device id; a wrong code keeps the dialog open (A3).
  Future<void> _newDeviceFlow(_LoginAttempt base) async {
    if (!mounted) return;
    final l = _l;
    var last = base;
    final result = await showVerificationCodeDialog(
      context,
      kind: VerificationCodeKind.newDeviceOtp,
      title: l.newDeviceTitle,
      message: l.newDevicePrompt,
      onResend: () => _resendNewDeviceOtp(base),
      onSubmit: (code, _) {
        last = base.withNewDeviceOtp(code);
        return _submitCode(last, newDevice: true);
      },
    );
    if (!mounted) return;
    switch (result.outcome) {
      case VerificationDialogOutcome.accepted:
        return;
      case VerificationDialogOutcome.cancelled:
      case VerificationDialogOutcome.anotherMethod:
        _cancelPendingLogin();
        return;
      case VerificationDialogOutcome.flowChanged:
        final error = result.error;
        if (error is TwoFactorRequiredException) {
          await _twoFactorFlow(error, last);
        } else if (error != null) {
          _showLoginError(error);
        }
    }
  }

  /// Store screenshots (DEMO_MODE=totp): the code dialog over the form.
  void _showDemoTotpDialog() {
    final l = _l;
    showVerificationCodeDialog(
      context,
      kind: VerificationCodeKind.totp,
      title: l.twoFactorTitle,
      message: l.twoFactorPrompt,
      showRemember: true,
      onSubmit: (_, __) async => CodeRejected(l.errorInvalidTwoFactorCode),
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Theme.of(context).colorScheme.error,
        duration: const Duration(seconds: 6),
      ),
    );
  }

  String _progressLabel(AppLocalizations l) {
    final status = _statusMessage;
    if (status != null) return status;
    return switch (_step) {
      SetupStep.serverParameters => l.setupStepServerParameters,
      SetupStep.derivingKey => l.setupStepDerivingKey,
      SetupStep.authenticating => l.setupStepAuthenticating,
      SetupStep.decryptingKey => l.setupStepDecryptingKey,
      SetupStep.securingKeys => l.setupStepSecuringKeys,
      null => l.settingUp,
    };
  }

  // ── UI ──

  Widget _buildThemeToggle() {
    final mode = ref.watch(themeModeProvider);
    final IconData icon;
    switch (mode) {
      case ThemeMode.system:
        icon = Icons.brightness_auto;
      case ThemeMode.light:
        icon = Icons.light_mode;
      case ThemeMode.dark:
        icon = Icons.dark_mode;
    }
    return IconButton(
      icon: Icon(icon),
      tooltip: _l.themeTooltip(mode.name),
      onPressed: () {
        final isCurrentlyDark =
            MediaQuery.platformBrightnessOf(context) == Brightness.dark;
        final next = switch (mode) {
          ThemeMode.system =>
            isCurrentlyDark ? ThemeMode.light : ThemeMode.dark,
          ThemeMode.light => ThemeMode.system,
          ThemeMode.dark => ThemeMode.system,
        };
        ref.read(themeModeProvider.notifier).state = next;
      },
    );
  }

  /// F11/A9: why the user is back here (also shown once as a SnackBar).
  Widget _buildSessionNotice(ThemeData theme, SessionEndNotice notice) {
    final l = _l;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: ContentCard(
        padding: const EdgeInsets.all(14),
        borderColor: theme.colorScheme.error.withValues(alpha: 0.6),
        borderWidth: 1,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, color: theme.colorScheme.error),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                switch (notice) {
                  SessionEndNotice.sessionEnded => l.sessionEndedOnServer,
                  SessionEndNotice.signedOutByServer => l.signedOutByServer,
                },
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildServerSection(ThemeData theme) {
    final l = _l;
    final cloud = switch (_region) {
      ServerRegion.us => ServerEnvironment.us,
      ServerRegion.eu => ServerEnvironment.eu,
      ServerRegion.selfHosted => null,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l.serverSection,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        ServerSelector(
          region: _region,
          enabled: !_isLoading,
          onChanged: (r) => setState(() {
            _region = r;
            _certHighlight = false;
          }),
        ),
        const SizedBox(height: 16),
        if (cloud != null)
          Row(
            children: [
              Icon(
                Icons.cloud_outlined,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l.serverCloudCaption(Uri.parse(cloud.baseUrl).host),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          )
        else ...[
          Semantics(
            identifier: 'input_server_url',
            child: TextFormField(
              controller: _serverUrlController,
              decoration: InputDecoration(
                labelText: l.serverUrlLabel,
                hintText: l.serverUrlHint,
                prefixIcon: const Icon(Icons.dns_outlined),
                border: const OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
              autocorrect: false,
              enabled: !_isLoading,
              onEditingComplete: () {
                setState(() => _certUrl = _serverUrlController.text);
                FocusScope.of(context).nextFocus();
              },
              validator: (v) {
                final value = v?.trim() ?? '';
                if (value.isEmpty || value == 'https://') {
                  return l.serverUrlRequired;
                }
                try {
                  ServerEnvironment.normalizeBaseUrl(value);
                } on FormatException {
                  return l.serverUrlInvalid;
                }
                return null;
              },
            ),
          ),
          // Not in demo builds: importing would write the real keychain.
          if (!demoActive) ...[
            const SizedBox(height: 12),
            ClientCertificateSection(
              serverUrl: _certUrl,
              enabled: !_isLoading,
              highlight: _certHighlight,
              onChanged: () => setState(() => _certHighlight = false),
            ),
          ],
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = _l;
    final notice = ref.watch(sessionEndNoticeProvider);
    // Read above the Scaffold: its body's MediaQuery has the keyboard
    // inset removed.
    final keyboardUp = MediaQuery.viewInsetsOf(context).bottom > 0;

    return Scaffold(
      appBar: AppBar(
        actions: [_buildThemeToggle()],
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Icon(
                            Icons.shield_outlined,
                            size: 64,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            l.appTitle,
                            style: theme.textTheme.headlineSmall,
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            l.setupSubtitle,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 32),
                          if (notice != null)
                            _buildSessionNotice(theme, notice),
                          _buildServerSection(theme),
                          const SizedBox(height: 16),

                          // Email
                          TextFormField(
                            controller: _emailController,
                            decoration: InputDecoration(
                              labelText: l.emailLabel,
                              prefixIcon: const Icon(Icons.email_outlined),
                              border: const OutlineInputBorder(),
                            ),
                            keyboardType: TextInputType.emailAddress,
                            autocorrect: false,
                            enabled: !_isLoading,
                            validator: (v) {
                              if (v == null || v.trim().isEmpty) {
                                return l.emailRequired;
                              }
                              if (!v.contains('@')) return l.emailInvalid;
                              return null;
                            },
                          ),
                          const SizedBox(height: 16),

                          // Master Password
                          TextFormField(
                            controller: _passwordController,
                            decoration: InputDecoration(
                              labelText: l.masterPasswordLabel,
                              prefixIcon: const Icon(Icons.lock_outlined),
                              border: const OutlineInputBorder(),
                              suffixIcon: IconButton(
                                icon: Icon(
                                  _obscurePassword
                                      ? Icons.visibility_off
                                      : Icons.visibility,
                                ),
                                onPressed: () {
                                  setState(() =>
                                      _obscurePassword = !_obscurePassword);
                                },
                              ),
                            ),
                            obscureText: _obscurePassword,
                            enabled: !_isLoading,
                            onFieldSubmitted: (_) {
                              if (!_isLoading) _submit();
                            },
                            validator: (v) {
                              if (v == null || v.isEmpty) {
                                return l.masterPasswordRequired;
                              }
                              return null;
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // Primary action pinned under the scrolling form, so it is on
            // screen on every phone — also with the self-hosted URL and a
            // certificate card, and above the keyboard.
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: _buildSubmitButton(l),
              ),
            ),
            // While typing, the space goes to the form; the footer (and its
            // 5-tap demo gesture) is back as soon as the keyboard closes.
            if (keyboardUp)
              const SizedBox(height: 12)
            else
              _buildVersionFooter(theme),
          ],
        ),
      ),
    );
  }

  Widget _buildSubmitButton(AppLocalizations l) {
    return Semantics(
      identifier: 'btn_submit_setup',
      child: SizedBox(
        width: double.infinity,
        height: 48,
        child: FilledButton(
          onPressed: _isLoading ? null : _submit,
          child: _isLoading
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        _progressLabel(l),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                )
              : Text(l.setUp),
        ),
      ),
    );
  }

  Widget _buildVersionFooter(ThemeData theme) {
    if (_appVersion.isEmpty) return const SizedBox(height: 48);
    // Full-width, tall tap strip — the 5-tap demo gesture was hard to hit on
    // the bare text alone.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _onVersionTap,
      child: Container(
        width: double.infinity,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 24),
        child: Text(
          _appVersion,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }
}
