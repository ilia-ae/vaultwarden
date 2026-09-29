import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';

/// Bitwarden `TwoFactorProviderType` ids.
abstract final class TwoFactorProvider {
  static const authenticator = 0;
  static const email = 1;
  static const duo = 2;
  static const yubiKey = 3;
  static const u2f = 4;
  static const remember = 5;
  static const organizationDuo = 6;
  static const webAuthn = 7;
  static const recoveryCode = 8;

  /// Providers this app can complete (a typed code). Duo, U2F and WebAuthn
  /// need a browser/platform flow the app does not implement.
  static bool isSupported(int id) =>
      id == authenticator || id == email || id == yubiKey || id == recoveryCode;

  /// The choices to offer for a server's provider list: "remember" is never
  /// offered (the app tries a stored remember token on its own, A6), the
  /// recovery code is always offered last (both servers accept it even when
  /// it is not listed), supported methods come before unsupported ones.
  static List<int> choices(List<int> serverProviders) {
    final listed = <int>[];
    for (final id in serverProviders) {
      if (id == remember || id == recoveryCode || listed.contains(id)) continue;
      listed.add(id);
    }
    return [
      ...listed.where(isSupported),
      ...listed.where((id) => !isSupported(id)),
      recoveryCode,
    ];
  }

  /// The single method to use without asking, or null when the user has to
  /// pick (several usable methods, or none besides the recovery code).
  static int? automaticChoice(List<int> choices) {
    final usable =
        choices.where((id) => isSupported(id) && id != recoveryCode).toList();
    return usable.length == 1 ? usable.single : null;
  }
}

/// Localised name of a 2FA provider.
String twoFactorProviderName(int id, AppLocalizations l) => switch (id) {
      TwoFactorProvider.authenticator => l.twoFactorProviderAuthenticator,
      TwoFactorProvider.email => l.twoFactorProviderEmail,
      TwoFactorProvider.duo ||
      TwoFactorProvider.organizationDuo =>
        l.twoFactorProviderDuo,
      TwoFactorProvider.yubiKey => l.twoFactorProviderYubiKey,
      TwoFactorProvider.u2f => l.twoFactorProviderU2f,
      TwoFactorProvider.webAuthn => l.twoFactorProviderWebAuthn,
      TwoFactorProvider.recoveryCode => l.twoFactorProviderRecoveryCode,
      _ => l.twoFactorProviderUnknown(id),
    };

IconData _providerIcon(int id) => switch (id) {
      TwoFactorProvider.authenticator => Icons.pin_outlined,
      TwoFactorProvider.email => Icons.mail_outline,
      TwoFactorProvider.yubiKey => Icons.usb,
      TwoFactorProvider.recoveryCode => Icons.healing_outlined,
      TwoFactorProvider.webAuthn || TwoFactorProvider.u2f => Icons.key,
      _ => Icons.shield_outlined,
    };

/// Lets the user choose a two-step login method (F12). [choices] come from
/// [TwoFactorProvider.choices]; unsupported methods are listed but disabled
/// with "not supported — use another method". Returns the chosen id, or null
/// when cancelled.
Future<int?> showTwoFactorProviderPicker(
  BuildContext context, {
  required List<int> choices,
  String? obscuredEmail,
}) {
  return showDialog<int>(
    context: context,
    barrierDismissible: false,
    builder: (context) {
      final l = AppLocalizations.of(context)!;
      final theme = Theme.of(context);
      final cs = theme.colorScheme;
      final noneUsable = !choices.any((id) =>
          TwoFactorProvider.isSupported(id) &&
          id != TwoFactorProvider.recoveryCode);

      String subtitle(int id) => switch (id) {
            TwoFactorProvider.authenticator =>
              l.twoFactorProviderAuthenticatorHint,
            TwoFactorProvider.email => obscuredEmail == null
                ? l.twoFactorProviderEmailHint
                : l.twoFactorProviderEmailHintTo(obscuredEmail),
            TwoFactorProvider.yubiKey => l.twoFactorProviderYubiKeyHint,
            TwoFactorProvider.recoveryCode =>
              l.twoFactorProviderRecoveryCodeHint,
            _ => l.twoFactorNotSupported,
          };

      return AlertDialog(
        title: Text(l.twoFactorChooseTitle),
        contentPadding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              if (noneUsable)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    l.twoFactorNoSupportedMethod,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.error,
                    ),
                  ),
                ),
              for (final id in choices)
                Semantics(
                  identifier: 'twofactor_provider_$id',
                  child: ListTile(
                    enabled: TwoFactorProvider.isSupported(id),
                    leading: Icon(_providerIcon(id)),
                    title: Text(twoFactorProviderName(id, l)),
                    subtitle: Text(
                      subtitle(id),
                      style: id == TwoFactorProvider.recoveryCode
                          ? TextStyle(color: cs.error)
                          : null,
                    ),
                    onTap: () => Navigator.of(context).pop(id),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l.cancel),
          ),
        ],
      );
    },
  );
}

/// What the code dialog asks for.
enum VerificationCodeKind {
  /// Authenticator (TOTP): exactly 6 digits, submitted automatically.
  totp,

  /// E-mailed 2FA code: 6+ digits (Vaultwarden's size is configurable).
  email,

  /// YubiKey OTP: 44 modhex characters typed by the key (it presses Enter).
  yubiKey,

  /// Account recovery code (turns 2FA off on the server).
  recoveryCode,

  /// bitwarden.com new-device verification code: 6 or 8 digits.
  newDeviceOtp;

  bool get numeric => this == totp || this == email || this == newDeviceOtp;

  int get minLength => switch (this) {
        totp => 6,
        email => 6,
        yubiKey => 44,
        recoveryCode => 1,
        newDeviceOtp => 6,
      };

  int get maxLength => switch (this) {
        totp => 6,
        email => 19,
        yubiKey => 44,
        recoveryCode => 64,
        newDeviceOtp => 8,
      };

  /// Submitted as soon as the code is complete (fixed-length codes).
  bool get autoSubmit => this == totp || this == yubiKey;

  /// The code as the server expects it.
  String normalize(String input) => switch (this) {
        // Recovery codes are shown in groups; servers compare lowercase
        // without spaces.
        recoveryCode => input.replaceAll(RegExp(r'\s'), '').toLowerCase(),
        _ => input.trim(),
      };
}

/// Outcome of one code submission (see [showVerificationCodeDialog]).
sealed class CodeSubmitResult {
  const CodeSubmitResult();
}

/// The server accepted the code — the dialog closes.
final class CodeAccepted extends CodeSubmitResult {
  const CodeAccepted();
}

/// Wrong/expired code or a transient error: shown inline, the dialog stays
/// open for another try (A3/A4).
final class CodeRejected extends CodeSubmitResult {
  const CodeRejected(this.message);
  final String message;
}

/// The server wants something else now (e.g. new-device verification after
/// 2FA): the dialog closes and hands [error] to the caller.
final class CodeFlowChanged extends CodeSubmitResult {
  const CodeFlowChanged(this.error);
  final Object error;
}

enum VerificationDialogOutcome {
  accepted,
  cancelled,
  anotherMethod,
  flowChanged
}

class VerificationDialogResult {
  const VerificationDialogResult(this.outcome, [this.error]);
  final VerificationDialogOutcome outcome;

  /// Set for [VerificationDialogOutcome.flowChanged].
  final Object? error;
}

/// Code entry for 2FA and new-device verification. The code is submitted
/// from inside the dialog ([onSubmit]); a rejected code keeps the dialog open
/// with an inline error. [onResend] (e-mail codes) returns null on success
/// or the error text.
Future<VerificationDialogResult> showVerificationCodeDialog(
  BuildContext context, {
  required VerificationCodeKind kind,
  required String title,
  required String message,
  required Future<CodeSubmitResult> Function(String code, bool remember)
      onSubmit,
  Future<String?> Function()? onResend,
  bool showRemember = false,
  bool initialRemember = true,
  bool offerAnotherMethod = false,
  String? initialError,
  String? initialInfo,
}) async {
  final result = await showDialog<VerificationDialogResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => VerificationCodeDialog(
      kind: kind,
      title: title,
      message: message,
      onSubmit: onSubmit,
      onResend: onResend,
      showRemember: showRemember,
      initialRemember: initialRemember,
      offerAnotherMethod: offerAnotherMethod,
      initialError: initialError,
      initialInfo: initialInfo,
    ),
  );
  return result ??
      const VerificationDialogResult(VerificationDialogOutcome.cancelled);
}

/// See [showVerificationCodeDialog].
class VerificationCodeDialog extends StatefulWidget {
  const VerificationCodeDialog({
    super.key,
    required this.kind,
    required this.title,
    required this.message,
    required this.onSubmit,
    this.onResend,
    this.showRemember = false,
    this.initialRemember = true,
    this.offerAnotherMethod = false,
    this.initialError,
    this.initialInfo,
  });

  final VerificationCodeKind kind;
  final String title;
  final String message;
  final Future<CodeSubmitResult> Function(String code, bool remember) onSubmit;
  final Future<String?> Function()? onResend;
  final bool showRemember;
  final bool initialRemember;
  final bool offerAnotherMethod;
  final String? initialError;
  final String? initialInfo;

  @override
  State<VerificationCodeDialog> createState() => _VerificationCodeDialogState();
}

class _VerificationCodeDialogState extends State<VerificationCodeDialog> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  late bool _remember = widget.initialRemember;
  late String? _error = widget.initialError;
  late String? _info = widget.initialInfo;
  bool _busy = false;
  bool _resending = false;

  VerificationCodeKind get _kind => widget.kind;

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _close(VerificationDialogResult result) {
    if (mounted) Navigator.of(context).pop(result);
  }

  Future<void> _submit() async {
    if (_busy) return;
    final l = AppLocalizations.of(context)!;
    final code = _kind.normalize(_controller.text);
    if (code.length < _kind.minLength) {
      setState(() {
        _error = _kind == VerificationCodeKind.totp
            ? l.twoFactorCodeError
            : l.codeIncomplete;
        _info = null;
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    final CodeSubmitResult result;
    try {
      result = await widget.onSubmit(code, _remember);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString();
      });
      return;
    }
    if (!mounted) return;
    switch (result) {
      case CodeAccepted():
        _close(
            const VerificationDialogResult(VerificationDialogOutcome.accepted));
      case CodeFlowChanged(:final error):
        _close(VerificationDialogResult(
            VerificationDialogOutcome.flowChanged, error));
      case CodeRejected(:final message):
        setState(() {
          _busy = false;
          _error = message;
          _controller.clear();
        });
        _focus.requestFocus();
    }
  }

  Future<void> _resend() async {
    final onResend = widget.onResend;
    if (onResend == null || _resending) return;
    final l = AppLocalizations.of(context)!;
    setState(() {
      _resending = true;
      _info = null;
      _error = null;
    });
    String? error;
    try {
      error = await onResend();
    } catch (e) {
      error = e.toString();
    }
    if (!mounted) return;
    setState(() {
      _resending = false;
      if (error == null) {
        _info = l.codeSent;
      } else {
        _error = error;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final numeric = _kind.numeric;
    final isTotp = _kind == VerificationCodeKind.totp;

    return AlertDialog(
      title: Text(widget.title),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.message),
          const SizedBox(height: 16),
          Semantics(
            identifier: 'input_totp',
            child: TextField(
              controller: _controller,
              focusNode: _focus,
              autofocus: true,
              enabled: !_busy,
              keyboardType: numeric
                  ? TextInputType.number
                  : TextInputType.visiblePassword,
              autocorrect: false,
              enableSuggestions: false,
              textAlign: numeric ? TextAlign.center : TextAlign.start,
              style: numeric
                  ? const TextStyle(fontSize: 24, letterSpacing: 8)
                  : const TextStyle(fontFamily: 'monospace'),
              inputFormatters: [
                if (numeric) FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(_kind.maxLength),
              ],
              decoration: InputDecoration(
                hintText: isTotp ? l.twoFactorHint : null,
                border: const OutlineInputBorder(),
                errorText: _error,
                errorMaxLines: 4,
              ),
              onChanged: (v) {
                if (_error != null) setState(() => _error = null);
                // Auto-submit fixed-length codes (typed or pasted; a
                // YubiKey types all 44 characters at once).
                if (_kind.autoSubmit &&
                    _kind.normalize(v).length == _kind.maxLength) {
                  _submit();
                }
              },
              onSubmitted: (_) => _submit(),
            ),
          ),
          if (_info != null) ...[
            const SizedBox(height: 8),
            Text(
              _info!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ],
          if (widget.showRemember) ...[
            const SizedBox(height: 8),
            Semantics(
              identifier: 'chk_remember_device',
              child: CheckboxListTile(
                value: _remember,
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _remember = v ?? false),
                title: Text(l.twoFactorRemember),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                dense: true,
              ),
            ),
          ],
          if (widget.onResend != null || widget.offerAnotherMethod) ...[
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              children: [
                if (widget.onResend != null)
                  Semantics(
                    identifier: 'btn_resend_code',
                    child: TextButton.icon(
                      onPressed: _busy || _resending ? null : _resend,
                      icon: _resending
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh, size: 18),
                      label: Text(l.resendCode),
                    ),
                  ),
                if (widget.offerAnotherMethod)
                  Semantics(
                    identifier: 'btn_another_method',
                    child: TextButton(
                      onPressed: _busy
                          ? null
                          : () => _close(const VerificationDialogResult(
                              VerificationDialogOutcome.anotherMethod)),
                      child: Text(l.twoFactorAnotherMethod),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy
              ? null
              : () => _close(const VerificationDialogResult(
                  VerificationDialogOutcome.cancelled)),
          child: Text(l.cancel),
        ),
        Semantics(
          identifier: 'btn_totp_verify',
          child: FilledButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l.verify),
          ),
        ),
      ],
    );
  }
}
