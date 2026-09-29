// Trace C0.9: objects that carry secrets redact themselves in toString (a
// ProviderObserver, an error report or a debug print must never show one).
// Trace BW12: Ledger fields set by hand during the transition are neither
// derived, shown nor exported.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/pin_tools/ledger_pin24.dart' show bip39ToSeed;
import 'package:vault_approver/pin_tools/yubikey_ledger.dart';
import 'package:vault_approver/pin_tools/yubikey_secrets.dart';
import 'package:vault_approver/screens/pin/pin24_engine.dart';
import 'package:vault_approver/screens/pin/pin_session.dart';
import 'package:vault_approver/screens/pin/yubikey_engine.dart';

const _abandon12 = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';
const _master = 'SYNTHETIC-TEST-MASTER-KEY-A-0123456789abcdef';

/// Every string representation a logger might use.
List<String> _renderings(Object o) => [
      '$o',
      o.toString(),
      '${[o]}',
      '${{'k': o}}'
    ];

void _expectRedacted(Object o, List<String> secrets) {
  for (final text in _renderings(o)) {
    for (final secret in secrets) {
      expect(text, isNot(contains(secret)), reason: '${o.runtimeType}: $text');
    }
  }
}

void main() {
  group('C0.9: toString redacts secrets', () {
    test('PIN 24 request, seed request and response', () {
      _expectRedacted(
        const Pin24Request(
          canonicalPhrase: _abandon12,
          passphrase: 'TREZOR',
          nickname: 'visa',
          mode: Pin24Mode.pin,
          length: 4,
          setMask: 0,
        ),
        ['abandon', 'about', 'TREZOR', 'visa'],
      );
      _expectRedacted(
        Pin24Request(
          cachedSeed: Uint8List.fromList(List.filled(64, 0xAB)),
          nickname: 'visa',
          mode: Pin24Mode.password,
          length: 4,
          setMask: 7,
        ),
        ['visa', '171', 'ab, ab', 'AB'],
      );
      _expectRedacted(
        const Pin24SeedRequest(canonicalPhrase: _abandon12, passphrase: 'pp'),
        ['abandon', 'pp)'],
      );
      final r = pin24Compute(const Pin24Request(
        canonicalPhrase: _abandon12,
        nickname: 'visa',
        mode: Pin24Mode.pin,
        length: 4,
        setMask: 0,
      ));
      expect(r.pin, '0853');
      _expectRedacted(r, ['0853', r.fullPassword!, '${r.freshSeed!.first},']);
      final seedOnly =
          pin24SeedCompute(const Pin24SeedRequest(canonicalPhrase: _abandon12));
      expect(seedOnly.freshSeed, bip39ToSeed(_abandon12));
      _expectRedacted(seedOnly, [seedOnly.freshSeed!.take(4).join(', ')]);
    });

    test('YubiKey request, key result and response', () {
      final request = YkRequest(
        source: YkSource.master,
        serials: const ['12345678'],
        phases: const {YkPhase.openpgp},
        otpFromSerial: true,
        masterBytes: Uint8List.fromList(utf8.encode(_master)),
        randomValues: const {
          '12345678': {'25': 'RandomSecret123'}
        },
      );
      _expectRedacted(request, ['SYNTHETIC', 'RandomSecret123', '83, 89']);
      final response = ykCompute(YkRequest(
        source: YkSource.master,
        serials: const ['12345678'],
        phases: const {YkPhase.openpgp},
        otpFromSerial: true,
        masterBytes: Uint8List.fromList(utf8.encode(_master)),
      ));
      final key = response.keys.single;
      expect(key.values['00'], '77747579');
      final values = key.values.values.toList();
      _expectRedacted(key, values);
      _expectRedacted(response, values);
    });

    test('PinSession, PinSeedCache and the YubiKey settings', () {
      final session = PinSession();
      addTearDown(session.dispose);
      final seed = bip39ToSeed(_abandon12);
      final shown = seed.take(6).join(', ');
      session.seed.store(
          PinSeedCache.keyFor(_abandon12, ''), Uint8List.fromList(seed),
          wordCount: 12);
      session.yk.serials = '38715242';
      _expectRedacted(session, [shown, 'abandon']);
      _expectRedacted(session.seed, [shown, 'abandon']);
      _expectRedacted(session.yk, [shown]);
      const event = PinWipeEvent(
          serial: 1,
          scope: PinWipeScope.all,
          reason: PinWipeReason.left,
          hadContent: true);
      expect('$event', 'PinWipeEvent(1, PinWipeScope.all, PinWipeReason.left)');
    });
  });

  group('BW12: fields set by hand (Ledger source)', () {
    final seed = bip39ToSeed(_abandon12);

    YkResponse compute(Set<String> handSet) => ykCompute(YkRequest(
          source: YkSource.ledger,
          serials: const ['38715242'],
          phases: const {YkPhase.openpgp, YkPhase.fido2},
          otpFromSerial: true,
          seed: Uint8List.fromList(seed),
          handSet: handSet,
        ));

    test('a hand-set field is not derived, shown or exported', () {
      final all = compute(const {}).keys.single;
      expect(all.values.keys, containsAll(['00', '23', '34']));
      expect(all.handSetFields, isEmpty);

      final k = compute(const {'00', '34'}).keys.single;
      expect(k.handSetFields, ['00', '34']);
      expect(k.values.keys, isNot(contains('00')));
      expect(k.values.keys, isNot(contains('34')));
      // The others are unchanged Ledger values.
      expect(k.values['23'], all.values['23']);
      expect(k.values['14'], all.values['14']);
      expect(k.origins['23'], YkOrigin.ledger);
      // No "PIV PIN is part of …" warning about a PIN that is not derived.
      expect(k.warnings['00'], isNull);
      final csv = ykBitwardenCsv([k.secrets]);
      expect(csv, isNot(contains(',00 ')));
      expect(csv, isNot(contains(',34 ')));
      expect(csv, contains(',23 '));
      expect(csv, contains(',14 '));
    });

    test('hand-set applies to the Ledger source and needed fields only', () {
      // FIDO2 off: 34 is not needed, so it is not reported either.
      final k = ykCompute(YkRequest(
        source: YkSource.ledger,
        serials: const ['38715242'],
        phases: const {YkPhase.openpgp},
        otpFromSerial: true,
        seed: Uint8List.fromList(seed),
        handSet: const {'34', '14'}, // 14 is not hand-settable
      )).keys.single;
      expect(k.handSetFields, isEmpty);
      expect(k.values.keys, contains('14'));

      final m = ykCompute(YkRequest(
        source: YkSource.master,
        serials: const ['12345678'],
        phases: const {YkPhase.openpgp},
        otpFromSerial: true,
        masterBytes: Uint8List.fromList(utf8.encode(_master)),
        handSet: const {'00'},
      )).keys.single;
      expect(m.values.keys, contains('00'), reason: 'master source ignores it');
    });

    test('matches the yubikey_ledger fixture for the fields it keeps', () {
      final fixture = jsonDecode(
          File('test/pin_tools/fixtures/yubikey_ledger.json')
              .readAsStringSync()) as Map<String, dynamic>;
      final v = (fixture['vectors'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((v) =>
              v['seed'] == 'abandon12' &&
              v['serial'] == '38715242' &&
              v['mask_name'] == 'device_default');
      final k = compute(const {'00'}).keys.single;
      expect(k.values['23'], (v['pins'] as Map)['full']);
      expect(k.values['14'], (v['puk'] as Map)['first4_last4']);
      expect(k.entryNames, ['yk-38715242-pins', 'yk-38715242-puk']);
      expect(ykLedgerFields, containsAll(kYkHandSettableFields));
    });
  });
}
