// Guard: nothing reachable from the PIN tools may talk to the network, share
// or log. Walks the import graph of lib/screens/pin and lib/pin_tools
// (following relative and package:vault_approver imports) and checks every
// external import against a deny list.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _roots = ['lib/screens/pin', 'lib/pin_tools'];

/// External libraries that can reach the network, share data or read files.
const _deniedPrefixes = [
  'dart:io',
  'dart:html',
  'dart:js',
  'dart:js_interop',
  'package:dio/',
  'package:http/',
  'package:web_socket_channel/',
  'package:cloud_firestore/',
  'package:firebase_',
  'package:google_sign_in',
  'package:sign_in_with_apple/',
  'package:url_launcher/',
  'package:share_plus/',
  'package:share/',
  'package:qr',
  'package:msgpack_dart/',
];

/// App libraries that do networking, sync or hold the session.
const _deniedAppFiles = [
  'lib/app.dart',
  'lib/services/vault_api.dart',
  'lib/services/notification_service.dart',
  'lib/services/settings_sync.dart',
  'lib/services/auth_service.dart',
  'lib/services/settings_service.dart',
  'lib/models/settings_snapshot.dart',
];

final _directive = RegExp(
  r'''^\s*(?:import|export|part)\s+['"]([^'"]+)['"]''',
  multiLine: true,
);

void main() {
  test('PIN code imports nothing that can reach the network', () {
    final queue = <String>[
      for (final root in _roots)
        ...Directory(root)
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .map((f) => f.path),
    ];
    expect(queue, isNotEmpty);
    final seen = <String>{};
    final violations = <String>[];
    while (queue.isNotEmpty) {
      final path = queue.removeLast();
      if (!seen.add(path)) continue;
      final file = File(path);
      if (!file.existsSync()) continue; // generated l10n parts etc.
      for (final m in _directive.allMatches(file.readAsStringSync())) {
        final uri = m.group(1)!;
        String? local;
        if (uri.startsWith('package:vault_approver/')) {
          local = 'lib/${uri.substring('package:vault_approver/'.length)}';
        } else if (!uri.contains(':')) {
          local = _normalize('${File(path).parent.path}/$uri');
        }
        if (local != null) {
          if (_deniedAppFiles.contains(local) ||
              local.startsWith('lib/providers/')) {
            violations.add('$path → $local');
          }
          queue.add(local);
        } else if (_deniedPrefixes.any(uri.startsWith)) {
          violations.add('$path → $uri');
        }
      }
    }
    expect(seen.length, greaterThan(10), reason: 'the walk found the files');
    expect(violations, isEmpty);
  });

  test('PIN screens and cores never print, log, share or restore secrets', () {
    final sources = [
      for (final root in _roots)
        ...Directory(root)
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart')),
    ];
    expect(sources.where((f) => f.path.contains('pin_tools')), isNotEmpty);
    for (final f in sources) {
      final code = f
          .readAsLinesSync()
          .where((line) => !line.trimLeft().startsWith('//'))
          .join('\n');
      for (final banned in [
        RegExp(r'\bprint\('),
        RegExp(r'\bdebugPrint\('),
        RegExp(r'\bdeveloper\.log\('),
        RegExp(r'restorationId\s*:'),
        RegExp(r'\bClipboard\.setData\('),
        RegExp(r'\bSelectableText\b'),
      ]) {
        expect(banned.hasMatch(code), isFalse,
            reason: '${f.path} uses ${banned.pattern}');
      }
    }
  });
}

String _normalize(String path) {
  final out = <String>[];
  for (final part in path.split('/')) {
    if (part == '..') {
      out.removeLast();
    } else if (part != '.' && part.isNotEmpty) {
      out.add(part);
    }
  }
  return out.join('/');
}
