import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../services/settings_sync.dart';
import '../utils/error_formatter.dart';
import '../utils/external_picker.dart';
import 'control_id.dart';

/// "Delete account" for the cloud-sync account (App Store guideline
/// 5.1.1(v)). After a confirmation, [SettingsSyncCoordinator.deleteAccount]
/// confirms the identity again with Apple or Google and deletes the account
/// and its settings document. The vault account and on-device data are not
/// touched.
class CloudAccountDeleteButton extends ConsumerStatefulWidget {
  const CloudAccountDeleteButton({super.key});

  @override
  ConsumerState<CloudAccountDeleteButton> createState() =>
      _CloudAccountDeleteButtonState();
}

class _CloudAccountDeleteButtonState
    extends ConsumerState<CloudAccountDeleteButton> {
  bool _busy = false;

  Future<void> _delete() async {
    if (_busy) return;
    final l = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.cloudSyncDeleteTitle),
        content: SingleChildScrollView(child: Text(l.cloudSyncDeleteBody)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.cancel),
          ),
          ControlId(
            'btn_confirm_delete_account',
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: Text(l.cloudSyncDeleteAccount),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // Once the account is gone the section rebuilds as signed out and this
    // button leaves the tree, so the outcome is shown from the navigator.
    final navigator = Navigator.of(context);
    setState(() => _busy = true);
    Object? error;
    try {
      // On Android the Google sheet can send the app to the background: keep
      // the auto-lock from closing this sheet while it is up.
      await runExternalPicker(
          () => ref.read(settingsSyncCoordinatorProvider).deleteAccount());
    } catch (e) {
      error = e;
    }
    if (mounted) setState(() => _busy = false);
    if (!navigator.mounted) return;

    final String title;
    final String? body;
    if (error == null) {
      title = l.cloudSyncDeleteDoneTitle;
      body = l.cloudSyncDeleteDoneBody;
    } else {
      title = l.cloudSyncDeleteFailedTitle;
      body = describeCloudDeleteError(error, l);
    }
    if (body == null) return; // the confirming sign-in was cancelled
    await showDialog<void>(
      context: navigator.context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SelectableText(body!),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l.ok),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final error = Theme.of(context).colorScheme.error;
    return SizedBox(
      width: double.infinity,
      child: ControlId(
        'btn_delete_cloud_account',
        child: TextButton.icon(
          style: TextButton.styleFrom(foregroundColor: error),
          onPressed: _busy ? null : _delete,
          icon: _busy
              ? SizedBox(
                  width: 16,
                  height: 16,
                  child:
                      CircularProgressIndicator(strokeWidth: 2, color: error),
                )
              : const Icon(Icons.delete_forever_outlined, size: 18),
          label: Text(_busy ? l.cloudSyncDeleting : l.cloudSyncDeleteAccount),
        ),
      ),
    );
  }
}
