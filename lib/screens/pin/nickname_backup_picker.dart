import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../utils/external_picker.dart';
import 'nickname_backup.dart';

/// Opens the system file picker for a Ledger Passwords backup and returns
/// its bytes, or `null` when the user cancelled. Throws
/// [NicknameBackupException] (a file over the size limit).
typedef NicknameBackupPicker = Future<Uint8List?> Function();

/// The picker PIN 24's import uses (widget tests override it).
///
/// The only file access of the PIN section: a file the user picked, read
/// once, never written. The PIN section offers it only while no seed is
/// entered or cached, because the picker sends the app to the background.
final nicknameBackupPickerProvider =
    Provider<NicknameBackupPicker>((_) => pickNicknameBackupFile);

/// Default [NicknameBackupPicker]: file_selector with JSON filters, wrapped
/// in [runExternalPicker] so that neither the auto-lock nor the PIN
/// section's background wipe fires while the picker is on screen.
Future<Uint8List?> pickNicknameBackupFile() async {
  const group = XTypeGroup(
    label: 'JSON',
    extensions: ['json'],
    // Android: files from chats or downloads often come untyped.
    mimeTypes: [
      'application/json',
      'text/json',
      'text/plain',
      'application/octet-stream',
    ],
    uniformTypeIdentifiers: ['public.json'],
  );
  final file = await runExternalPicker(
    () => openFile(acceptedTypeGroups: const [group]),
  );
  if (file == null) return null;
  return readNicknameBackupFile(file);
}

/// Reads [file], refusing one over [kNicknameBackupMaxBytes] before reading
/// it (and again if it turns out bigger than it said).
Future<Uint8List> readNicknameBackupFile(XFile file) async {
  const tooLarge = NicknameBackupException(NicknameBackupError.tooLarge);
  if (await file.length() > kNicknameBackupMaxBytes) throw tooLarge;
  final bytes = await file.readAsBytes();
  if (bytes.length > kNicknameBackupMaxBytes) throw tooLarge;
  return bytes;
}
