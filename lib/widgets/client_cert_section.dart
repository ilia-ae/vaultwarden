import 'dart:async';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../glass.dart';
import '../l10n/app_localizations.dart';
import '../providers/service_providers.dart';
import '../services/client_cert_service.dart';
import '../utils/error_formatter.dart';
import '../utils/external_picker.dart';
import 'control_id.dart';

/// A certificate file chosen by the user.
class PickedCertificateFile {
  const PickedCertificateFile({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

/// Opens the system file picker for a .p12/.pfx; null when cancelled.
typedef CertificateFilePicker = Future<PickedCertificateFile?> Function();

/// PKCS#12 bundles are a few kilobytes; anything bigger is not one.
const kMaxCertificateFileBytes = 1024 * 1024;

/// The picker used by [ClientCertificateSection] (tests override it).
final certificateFilePickerProvider =
    Provider<CertificateFilePicker>((_) => pickCertificateFile);

/// Default [CertificateFilePicker]: file_selector with PKCS#12 filters.
///
/// Wrapped in [runExternalPicker] so the auto-lock does not fire while the
/// system picker (a separate activity on Android) is on screen.
Future<PickedCertificateFile?> pickCertificateFile() async {
  const group = XTypeGroup(
    label: 'PKCS#12',
    extensions: ['p12', 'pfx'],
    // Android: files from chats/downloads often come as octet-stream.
    mimeTypes: [
      'application/x-pkcs12',
      'application/pkcs12',
      'application/octet-stream',
    ],
    // iOS: com.rsa.pkcs-12 covers both .p12 and .pfx.
    uniformTypeIdentifiers: ['com.rsa.pkcs-12'],
  );
  final file = await runExternalPicker(
    () => openFile(acceptedTypeGroups: const [group]),
  );
  if (file == null) return null;
  return readCertificateFile(file);
}

/// Reads a picked certificate into a buffer this app owns.
///
/// file_selector on Android hands back the platform channel's unmodifiable
/// view, which cannot be zeroed after the import; copying it here lets
/// [ClientCertificateSection] wipe the PKCS#12 bytes it holds.
Future<PickedCertificateFile> readCertificateFile(XFile file) async {
  if (await file.length() > kMaxCertificateFileBytes) {
    throw const ClientCertUnsupportedFormatException('file too large');
  }
  final raw = await file.readAsBytes();
  if (raw.length > kMaxCertificateFileBytes) {
    throw const ClientCertUnsupportedFormatException('file too large');
  }
  return PickedCertificateFile(name: file.name, bytes: Uint8List.fromList(raw));
}

/// Zeroes [bytes] when the buffer allows it (a picker may still hand over an
/// unmodifiable view; wiping must never break the import).
void wipeCertificateBytes(Uint8List bytes) {
  try {
    bytes.fillRange(0, bytes.length, 0);
  } on UnsupportedError {
    // Unmodifiable view: nothing this app can overwrite.
  }
}

/// Formats a certificate date (local, e.g. "Sep 27, 2026").
String formatCertificateDate(BuildContext context, DateTime date) {
  final local = date.toLocal();
  try {
    return DateFormat.yMMMd(Localizations.localeOf(context).toLanguageTag())
        .format(local);
  } catch (_) {
    return MaterialLocalizations.of(context).formatCompactDate(local);
  }
}

/// `CN=ilia.ae mTLS CA, O=ilia.ae` → `ilia.ae mTLS CA`.
String certificateDisplayName(String dn) {
  for (final part in dn.split(RegExp(r',\s*'))) {
    final trimmed = part.trim();
    if (trimmed.toUpperCase().startsWith('CN=')) return trimmed.substring(3);
  }
  return dn;
}

/// "Client certificate (mTLS)" row for one server (F1, A14): shows the
/// stored certificate (subject, issuer, expiry with a warning under 30 days)
/// and imports, replaces or removes it. Certificates are stored per origin
/// (`scheme://host:port`) of [serverUrl].
class ClientCertificateSection extends ConsumerStatefulWidget {
  const ClientCertificateSection({
    super.key,
    required this.serverUrl,
    this.enabled = true,
    this.highlight = false,
    this.margin,
    this.onChanged,
  });

  /// Server URL as entered/stored; null or invalid = "enter the URL first".
  final String? serverUrl;
  final bool enabled;

  /// Draws attention to the row (the server just demanded a certificate).
  final bool highlight;
  final EdgeInsetsGeometry? margin;

  /// Called after a successful import or removal.
  final VoidCallback? onChanged;

  @override
  ConsumerState<ClientCertificateSection> createState() =>
      _ClientCertificateSectionState();
}

class _ClientCertificateSectionState
    extends ConsumerState<ClientCertificateSection> {
  late final ClientCertService _service = ref.read(clientCertServiceProvider);
  StreamSubscription<String>? _changes;
  String? _origin;
  ClientCertificateInfo? _info;
  bool _loading = false;
  bool _busy = false;
  int _generation = 0;

  /// Result of the last action, shown inside the card: in Settings the row
  /// sits in a modal sheet, which would cover a SnackBar.
  String? _status;
  bool _statusIsError = false;

  static String? _originOf(String? url) {
    if (url == null) return null;
    final trimmed = url.trim();
    if (trimmed.isEmpty || trimmed == 'https://' || trimmed == 'http://') {
      return null;
    }
    try {
      return ClientCertService.originOf(trimmed);
    } on FormatException {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    _changes = _service.changes.listen((origin) {
      if (origin == _origin && mounted) setState(() => unawaited(_reload()));
    });
    _origin = _originOf(widget.serverUrl);
    unawaited(_reload());
  }

  @override
  void didUpdateWidget(covariant ClientCertificateSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    final origin = _originOf(widget.serverUrl);
    if (origin != _origin) {
      _origin = origin;
      _status = null;
      unawaited(_reload());
    }
  }

  @override
  void dispose() {
    _changes?.cancel();
    super.dispose();
  }

  /// Re-reads the certificate of [_origin]. Only assigns fields before the
  /// first await (callers are initState/didUpdateWidget, which build next,
  /// or the changes stream, which rebuilds when the read completes).
  Future<void> _reload() async {
    final generation = ++_generation;
    final origin = _origin;
    if (origin == null) {
      _info = null;
      _loading = false;
      return;
    }
    _loading = true;
    ClientCertificateInfo? info;
    try {
      info = await _service.info(origin);
    } catch (_) {
      info = null; // unreadable keychain entry: treat as none
    }
    if (!mounted || generation != _generation) return;
    setState(() {
      _info = info;
      _loading = false;
    });
  }

  void _report(String message, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _status = message;
      _statusIsError = error;
    });
  }

  Future<void> _import() async {
    final origin = _origin;
    if (origin == null || _busy) return;
    final l = AppLocalizations.of(context)!;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final PickedCertificateFile? file;
      try {
        file = await ref.read(certificateFilePickerProvider)();
      } on ClientCertException catch (e) {
        _report(formatError(e, l), error: true);
        return;
      } catch (_) {
        _report(l.clientCertPickFailed, error: true);
        return;
      }
      if (file == null) return;
      final bytes = file.bytes;
      if (!mounted) {
        wipeCertificateBytes(bytes);
        return;
      }
      if (bytes.isEmpty || bytes.length > kMaxCertificateFileBytes) {
        wipeCertificateBytes(bytes);
        _report(
          formatError(const ClientCertUnsupportedFormatException('size'), l),
          error: true,
        );
        return;
      }
      // The dialog shows its own progress; the row stays calm behind it.
      setState(() => _busy = false);
      ClientCertificateInfo? imported;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => CertificatePasswordDialog(
          fileName: file!.name,
          onSubmit: (password) async {
            try {
              imported = await _service.importCertificate(
                serverUrl: origin,
                pkcs12: bytes,
                password: password,
              );
              return null;
            } on ClientCertException catch (e) {
              return formatError(e, l);
            } catch (e) {
              return formatError(e, l);
            }
          },
        ),
      );
      wipeCertificateBytes(bytes);
      // Closing the dialog hands focus back to the URL field; don't let that
      // pop the keyboard up.
      FocusManager.instance.primaryFocus?.unfocus();
      final info = imported;
      if (info == null || !mounted) return;
      setState(() => _info = info);
      _report(l.clientCertImported);
      widget.onChanged?.call();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    final origin = _origin;
    if (origin == null || _busy) return;
    final l = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.clientCertRemoveTitle),
        content: Text(l.clientCertRemoveMessage(origin)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l.clientCertRemove),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      await _service.remove(origin);
      if (!mounted) return;
      setState(() => _info = null);
      _report(l.clientCertRemoved);
      widget.onChanged?.call();
    } catch (e) {
      _report(formatError(e, l), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    const warning = Color(0xFFFF9500); // iOS system orange
    final info = _info;
    final hasOrigin = _origin != null;
    final canAct = widget.enabled && hasOrigin && !_busy && !_loading;

    final expired = info?.isExpired() ?? false;
    final expiringSoon = !expired && (info?.isExpiringSoon() ?? false);

    final IconData icon;
    final Color iconColor;
    if (info == null) {
      icon = Icons.badge_outlined;
      iconColor = widget.highlight ? cs.error : cs.onSurfaceVariant;
    } else if (expired) {
      icon = Icons.gpp_bad_outlined;
      iconColor = cs.error;
    } else if (expiringSoon) {
      icon = Icons.gpp_maybe_outlined;
      iconColor = warning;
    } else {
      icon = Icons.verified_user_outlined;
      iconColor = const Color(0xFF34C759); // iOS system green
    }

    final secondary = theme.textTheme.bodySmall?.copyWith(
      color: cs.onSurfaceVariant,
    );
    final lines = <Widget>[];
    if (_loading) {
      lines.add(const Padding(
        padding: EdgeInsets.only(top: 6),
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ));
    } else if (!hasOrigin) {
      lines.add(Text(l.clientCertNeedsUrl, style: secondary));
    } else if (info == null) {
      lines.add(Text(l.clientCertNone, style: secondary));
    } else {
      final name = info.commonName ??
          (info.subject == null
              ? l.clientCertUnnamed
              : certificateDisplayName(info.subject!));
      lines.add(Text(
        name,
        style: theme.textTheme.bodyMedium,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ));
      final issuer = info.issuer;
      if (issuer != null && issuer.isNotEmpty) {
        lines.add(Text(
          l.clientCertIssuedBy(certificateDisplayName(issuer)),
          style: secondary,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ));
      }
      final notAfter = info.notAfter;
      if (notAfter != null) {
        final date = formatCertificateDate(context, notAfter);
        final String text;
        final Color color;
        if (expired) {
          text = l.clientCertExpired(date);
          color = cs.error;
        } else if (expiringSoon) {
          final days = info.timeLeft()!.inDays;
          text = l.clientCertExpiresSoon(days, date);
          color = warning;
        } else {
          text = l.clientCertValidUntil(date);
          color = cs.onSurfaceVariant;
        }
        lines.add(Semantics(
          identifier: 'text_cert_expiry',
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: color,
              fontWeight: expired || expiringSoon ? FontWeight.w600 : null,
            ),
          ),
        ));
      }
    }

    final status = _status;
    if (status != null && hasOrigin) {
      lines.add(Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Semantics(
          identifier: 'text_cert_status',
          liveRegion: true,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                _statusIsError
                    ? Icons.error_outline
                    : Icons.check_circle_outline,
                size: 16,
                color: _statusIsError ? cs.error : const Color(0xFF34C759),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  status,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _statusIsError ? cs.error : cs.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ));
    }

    return ContentCard(
      margin: widget.margin,
      padding: const EdgeInsetsDirectional.fromSTEB(16, 14, 12, 8),
      borderColor: widget.highlight && info == null ? cs.error : null,
      borderWidth: widget.highlight && info == null ? 1.5 : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(icon, color: iconColor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l.clientCertTitle, style: theme.textTheme.titleSmall),
                    const SizedBox(height: 2),
                    ...lines,
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 4,
            children: [
              if (info != null)
                Semantics(
                  identifier: 'btn_cert_remove',
                  child: TextButton(
                    style: TextButton.styleFrom(foregroundColor: cs.error),
                    onPressed: canAct ? _remove : null,
                    child: Text(l.clientCertRemove),
                  ),
                ),
              Semantics(
                identifier: 'btn_cert_import',
                child: TextButton.icon(
                  onPressed: canAct ? _import : null,
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          info == null ? Icons.file_open_outlined : Icons.sync,
                          size: 18,
                        ),
                  label: Text(
                      info == null ? l.clientCertImport : l.clientCertReplace),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Asks for the .p12/.pfx password and validates/imports inside the dialog:
/// a wrong password or an unusable file shows an inline error and the
/// dialog stays open. [onSubmit] returns null on success (the dialog
/// closes) or the error text.
class CertificatePasswordDialog extends StatefulWidget {
  const CertificatePasswordDialog({
    super.key,
    required this.fileName,
    required this.onSubmit,
  });

  final String fileName;
  final Future<String?> Function(String password) onSubmit;

  @override
  State<CertificatePasswordDialog> createState() =>
      _CertificatePasswordDialogState();
}

class _CertificatePasswordDialogState extends State<CertificatePasswordDialog> {
  final _controller = TextEditingController();
  bool _obscure = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await widget.onSubmit(_controller.text);
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return AlertDialog(
      icon: const Icon(Icons.badge_outlined),
      title: Text(l.clientCertPasswordTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l.clientCertPasswordPrompt(widget.fileName)),
          const SizedBox(height: 16),
          Semantics(
            identifier: 'input_cert_password',
            child: TextField(
              controller: _controller,
              autofocus: true,
              obscureText: _obscure,
              enableSuggestions: false,
              autocorrect: false,
              enabled: !_busy,
              keyboardType: TextInputType.visiblePassword,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: l.clientCertPasswordLabel,
                border: const OutlineInputBorder(),
                errorText: _error,
                errorMaxLines: 4,
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscure ? Icons.visibility_off : Icons.visibility,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(l.cancel),
        ),
        ControlId(
          'btn_cert_password_import',
          child: FilledButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l.clientCertImportAction),
          ),
        ),
      ],
    );
  }
}
