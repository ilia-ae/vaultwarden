import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../app.dart';
import '../demo_fixtures.dart';
import '../l10n/app_localizations.dart';
import '../providers/service_providers.dart';
import '../providers/session_provider.dart';
import '../services/vault_api.dart';
import '../utils/error_formatter.dart';

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

  bool _isLoading = false;
  String _statusMessage = '';
  bool _obscurePassword = true;
  bool _demoTotpShown = false;

  // Build-version footer + hidden 5-tap demo gesture (for testers).
  String _appVersion = '';
  int _demoTapCount = 0;
  DateTime? _lastDemoTap;

  @override
  void initState() {
    super.initState();
    _loadVersion();
    if (demoMode == 'totp') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_demoTotpShown) {
          _demoTotpShown = true;
          _showTotpDialog([0]);
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
    demoRuntime.value = true;
    // Bypass the lock gate (no real key) and rebuild the session so the app
    // routes straight into the fixture-backed RequestsScreen.
    ref.read(isLockedProvider.notifier).state = false;
    ref.invalidate(sessionProvider);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Demo mode — sample data, not a real account'),
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  @override
  void dispose() {
    _serverUrlController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit({String? twoFactorToken, int? twoFactorProvider}) async {
    if (!_formKey.currentState!.validate()) return;

    // Check biometrics before proceeding
    final biometric = ref.read(biometricServiceProvider);
    final available = await biometric.isAvailable();
    if (!available && mounted) {
      final l = AppLocalizations.of(context)!;
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
      if (retry == true) {
        return _submit(
          twoFactorToken: twoFactorToken,
          twoFactorProvider: twoFactorProvider,
        );
      }
      return;
    }

    setState(() {
      _isLoading = true;
      _statusMessage = '';
    });

    try {
      await ref.read(sessionProvider.notifier).setup(
            serverUrl: _serverUrlController.text.trim(),
            email: _emailController.text.trim(),
            masterPassword: _passwordController.text,
            onProgress: (status) {
              if (mounted) setState(() => _statusMessage = status);
            },
            twoFactorToken: twoFactorToken,
            twoFactorProvider: twoFactorProvider,
          );
      // Navigation handled by app.dart watching sessionProvider
    } on TwoFactorRequiredException catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _statusMessage = '';
        });
        _showTotpDialog(e.availableProviders);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _statusMessage = '';
        });
        _showError(_formatError(e));
      }
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Theme.of(context).colorScheme.error,
        duration: const Duration(seconds: 5),
      ),
    );
  }

  Future<void> _showTotpDialog(List<int> providers) async {
    final totpController = TextEditingController();
    String? errorText;

    final code = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(AppLocalizations.of(context)!.twoFactorTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(AppLocalizations.of(context)!.twoFactorPrompt),
              const SizedBox(height: 16),
              Semantics(
                identifier: 'input_totp',
                child: TextField(
                controller: totpController,
                autofocus: true,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 24, letterSpacing: 8),
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(6),
                ],
                decoration: InputDecoration(
                  hintText: AppLocalizations.of(context)!.twoFactorHint,
                  border: const OutlineInputBorder(),
                  errorText: errorText,
                ),
                onChanged: (v) {
                  if (errorText != null) {
                    setDialogState(() => errorText = null);
                  }
                  // Auto-submit when 6 digits entered or pasted
                  if (v.length == 6) {
                    Navigator.of(dialogContext).pop(v);
                  }
                },
                onSubmitted: (v) {
                  if (v.length == 6) {
                    Navigator.of(dialogContext).pop(v);
                  } else {
                    setDialogState(() => errorText = AppLocalizations.of(context)!.twoFactorCodeError);
                  }
                },
              ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(null),
              child: Text(AppLocalizations.of(context)!.cancel),
            ),
            Semantics(
              identifier: 'btn_totp_verify',
              child: FilledButton(
                onPressed: () {
                  final v = totpController.text.trim();
                  if (v.length == 6) {
                    Navigator.of(dialogContext).pop(v);
                  } else {
                    setDialogState(() => errorText = AppLocalizations.of(context)!.twoFactorCodeError);
                  }
                },
                child: Text(AppLocalizations.of(context)!.verify),
              ),
            ),
          ],
        ),
      ),
    );

    final capturedCode = code;
    Future.delayed(const Duration(milliseconds: 300), totpController.dispose);

    if (capturedCode != null && capturedCode.length == 6) {
      // Use TOTP provider (0) by default; pick first available if TOTP not in list
      final provider = providers.contains(0) ? 0 : (providers.isNotEmpty ? providers.first : 0);
      await _submit(twoFactorToken: capturedCode, twoFactorProvider: provider);
    }
  }

  String _formatError(Object e) {
    return formatError(e, AppLocalizations.of(context)!);
  }

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
      tooltip: AppLocalizations.of(context)!.themeTooltip(mode.name),
      onPressed: () {
        final isCurrentlyDark =
            MediaQuery.platformBrightnessOf(context) == Brightness.dark;
        final next = switch (mode) {
          ThemeMode.system => isCurrentlyDark ? ThemeMode.light : ThemeMode.dark,
          ThemeMode.light => ThemeMode.system,
          ThemeMode.dark => ThemeMode.system,
        };
        ref.read(themeModeProvider.notifier).state = next;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        actions: [
          _buildThemeToggle(),
        ],
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Form(
                    key: _formKey,
                    child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.shield_outlined,
                    size: 64,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    AppLocalizations.of(context)!.appTitle,
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    AppLocalizations.of(context)!.setupSubtitle,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 32),

                  // Server URL
                  TextFormField(
                    controller: _serverUrlController,
                    decoration: InputDecoration(
                      labelText: AppLocalizations.of(context)!.serverUrlLabel,
                      hintText: AppLocalizations.of(context)!.serverUrlHint,
                      prefixIcon: const Icon(Icons.dns_outlined),
                      border: const OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    enabled: !_isLoading,
                    validator: (v) {
                      if (v == null || v.trim().isEmpty || v.trim() == 'https://') {
                        return AppLocalizations.of(context)!.serverUrlRequired;
                      }
                      final uri = Uri.tryParse(v.trim());
                      if (uri == null || !uri.hasScheme) return AppLocalizations.of(context)!.serverUrlInvalid;
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),

                  // Email
                  TextFormField(
                    controller: _emailController,
                    decoration: InputDecoration(
                      labelText: AppLocalizations.of(context)!.emailLabel,
                      prefixIcon: const Icon(Icons.email_outlined),
                      border: const OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    enabled: !_isLoading,
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) return AppLocalizations.of(context)!.emailRequired;
                      if (!v.contains('@')) return AppLocalizations.of(context)!.emailInvalid;
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),

                  // Master Password
                  TextFormField(
                    controller: _passwordController,
                    decoration: InputDecoration(
                      labelText: AppLocalizations.of(context)!.masterPasswordLabel,
                      prefixIcon: const Icon(Icons.lock_outlined),
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility_off
                              : Icons.visibility,
                        ),
                        onPressed: () {
                          setState(() => _obscurePassword = !_obscurePassword);
                        },
                      ),
                    ),
                    obscureText: _obscurePassword,
                    enabled: !_isLoading,
                    validator: (v) {
                      if (v == null || v.isEmpty) return AppLocalizations.of(context)!.masterPasswordRequired;
                      return null;
                    },
                  ),
                  const SizedBox(height: 24),

                  // Submit button
                  Semantics(
                    identifier: 'btn_submit_setup',
                    child: SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: FilledButton(
                      onPressed: _isLoading ? null : () => _submit(),
                      child: _isLoading
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                ),
                                const SizedBox(width: 12),
                                Text(_statusMessage.isNotEmpty
                                    ? _statusMessage
                                    : AppLocalizations.of(context)!.settingUp),
                              ],
                            )
                          : Text(AppLocalizations.of(context)!.setUp),
                    ),
                  ),
                  ),
                ],
                    ),
                  ),
                ),
              ),
            ),
            _buildVersionFooter(theme),
          ],
        ),
      ),
    );
  }

  Widget _buildVersionFooter(ThemeData theme) {
    if (_appVersion.isEmpty) return const SizedBox(height: 24);
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 12),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _onVersionTap,
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
