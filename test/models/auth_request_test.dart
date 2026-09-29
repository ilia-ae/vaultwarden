import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/models/auth_request.dart';

AuthRequest _req(
  String id, {
  required DateTime created,
  String? device,
  bool? approved,
  DateTime? responded,
  Duration offset = Duration.zero,
}) =>
    AuthRequest(
      id: id,
      publicKey: 'pk',
      requestDeviceType: 'Web',
      requestIpAddress: '192.0.2.1',
      creationDate: created,
      requestDeviceIdentifier: device,
      requestApproved: approved,
      responseDate: responded,
      serverClockOffset: offset,
    );

void main() {
  final now = DateTime.now().toUtc();

  group('parsing', () {
    test('parses Vaultwarden camelCase JSON', () {
      final r = AuthRequest.fromJson({
        'id': 'abc-123',
        'publicKey': 'dGVzdA==',
        'requestDeviceType': 'Chrome',
        'requestIpAddress': '192.168.1.1',
        'key': null,
        'masterPasswordHash': null,
        'creationDate': '2025-01-15T10:30:00.123456Z',
        'responseDate': null,
        'requestApproved': null,
        'origin': 'vault.example.com',
        'object': 'auth-request',
      });
      expect(r.id, 'abc-123');
      expect(r.publicKey, 'dGVzdA==');
      expect(r.requestDeviceType, 'Chrome');
      expect(r.requestIpAddress, '192.168.1.1');
      expect(r.creationDate, DateTime.utc(2025, 1, 15, 10, 30, 0, 123, 456));
      expect(r.hasCreationDate, isTrue);
      expect(r.requestApproved, isNull);
      expect(r.responseDate, isNull);
      expect(r.isUnanswered, isTrue);
      expect(r.origin, 'vault.example.com');
    });

    test('parses Bitwarden PascalCase JSON incl. device identifier', () {
      final r = AuthRequest.fromJson({
        'Id': 'abc-123',
        'PublicKey': 'dGVzdA==',
        'RequestDeviceIdentifier': 'dev-1',
        'RequestDeviceTypeValue': 9,
        'RequestDeviceType': 'Chrome Extension',
        'RequestIpAddress': '10.0.0.1',
        'RequestCountryName': 'Germany',
        'CreationDate': '2025-06-01T12:00:00.1234567Z',
        'RequestApproved': false,
        'ResponseDate': null,
      });
      expect(r.id, 'abc-123');
      expect(r.requestDeviceIdentifier, 'dev-1');
      expect(r.requestDeviceTypeValue, 9);
      expect(r.requestCountryName, 'Germany');
      expect(r.requestApproved, isFalse);
      expect(r.isUnanswered, isTrue);
      expect(r.creationDate.year, 2025);
    });

    test('timestamps without offset are UTC, not local (A2)', () {
      final r = AuthRequest.fromJson({
        'id': '1',
        'publicKey': 'pk',
        'creationDate': '2025-06-01T12:00:00',
      });
      expect(r.creationDate, DateTime.utc(2025, 6, 1, 12));
      expect(r.creationDate.isUtc, isTrue);
    });

    test('explicit offsets are honoured', () {
      final r = AuthRequest.fromJson({
        'id': '1',
        'publicKey': 'pk',
        'creationDate': '2025-06-01T14:00:00+02:00',
      });
      expect(r.creationDate, DateTime.utc(2025, 6, 1, 12));
    });

    test('items without id or publicKey are skipped (A1)', () {
      expect(AuthRequest.tryParse({'publicKey': 'pk'}), isNull);
      expect(AuthRequest.tryParse({'id': '1'}), isNull);
      expect(AuthRequest.tryParse({'id': '', 'publicKey': 'pk'}), isNull);
      expect(AuthRequest.tryParse({'id': 5, 'publicKey': 'pk'}), isNull);
      expect(
        () => AuthRequest.fromJson({'id': '1'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('missing creationDate → never actionable (A2)', () {
      final r = AuthRequest.tryParse({'id': '1', 'publicKey': 'pk'})!;
      expect(r.hasCreationDate, isFalse);
      expect(r.isActionable, isFalse);
      expect(r.remaining(), Duration.zero);
      final garbage = AuthRequest.tryParse(
        {'id': '1', 'publicKey': 'pk', 'creationDate': 'yesterday'},
      )!;
      expect(garbage.hasCreationDate, isFalse);
      expect(garbage.isActionable, isFalse);
    });
  });

  group('5-minute window (F5)', () {
    test('fresh request is actionable with ~5 minutes left', () {
      final r = _req('1', created: now.subtract(const Duration(seconds: 30)));
      expect(r.isActionable, isTrue);
      expect(r.isExpired, isFalse);
      expect(r.remaining(), lessThanOrEqualTo(const Duration(minutes: 5)));
      expect(r.remaining(), greaterThan(const Duration(minutes: 4)));
      expect(r.minutesRemaining, 5);
    });

    test('older than 5 minutes → expired, not actionable', () {
      final r = _req('1', created: now.subtract(const Duration(minutes: 6)));
      expect(r.isActionable, isFalse);
      expect(r.isExpired, isTrue);
      expect(r.minutesRemaining, 0);
    });

    test('age is measured with the server clock offset', () {
      // Phone clock 10 minutes behind the server: a request created 6 min
      // ago on the server looks 4 min in the future locally.
      final serverNow = now.add(const Duration(minutes: 10));
      final created = serverNow.subtract(const Duration(minutes: 6));
      final withoutOffset = _req('1', created: created);
      final withOffset = _req(
        '1',
        created: created,
        offset: const Duration(minutes: 10),
      );
      expect(withoutOffset.isActionableAt(now), isTrue); // wrong clock
      expect(withOffset.isActionableAt(now), isFalse); // server time
      expect(withOffset.age(now), const Duration(minutes: 6));
    });

    test('remaining never exceeds the window (future timestamps)', () {
      final r = _req('1', created: now.add(const Duration(minutes: 3)));
      expect(r.remaining(now), const Duration(minutes: 5));
    });

    test('answered requests are not actionable', () {
      final created = now.subtract(const Duration(minutes: 1));
      expect(_req('1', created: created, approved: true).isActionable, isFalse);
      expect(
        _req('1', created: created, approved: false, responded: now)
            .isActionable,
        isFalse,
      );
    });

    test('copyWith keeps fields and updates fingerprint', () {
      final r = _req(
        '1',
        created: now,
        device: 'dev',
        offset: const Duration(seconds: 3),
      );
      final u = r.copyWith(fingerprint: 'a-b-c-d-e');
      expect(u.fingerprint, 'a-b-c-d-e');
      expect(u.requestDeviceIdentifier, 'dev');
      expect(u.serverClockOffset, const Duration(seconds: 3));
      expect(u.creationDate, r.creationDate);
    });
  });

  group('selectPending (F8)', () {
    test('drops answered, keeps newest per device, sorts newest first', () {
      final list = [
        _req('old-a',
            created: now.subtract(const Duration(minutes: 3)), device: 'A'),
        _req('new-a',
            created: now.subtract(const Duration(minutes: 1)), device: 'A'),
        _req('b',
            created: now.subtract(const Duration(minutes: 2)), device: 'B'),
        _req('approved',
            created: now.subtract(const Duration(seconds: 10)), approved: true),
        _req('denied',
            created: now.subtract(const Duration(seconds: 20)),
            approved: false,
            responded: now),
        _req('no-device', created: now.subtract(const Duration(seconds: 30))),
        _req('expired', created: now.subtract(const Duration(minutes: 7))),
      ];
      final result = AuthRequest.selectPending(list);
      expect(result.map((r) => r.id), ['no-device', 'new-a', 'b']);
    });

    test('includeExpired keeps unanswered expired ones', () {
      final list = [
        _req('expired', created: now.subtract(const Duration(minutes: 7))),
        _req('fresh', created: now.subtract(const Duration(minutes: 1))),
      ];
      expect(
        AuthRequest.selectPending(list, includeExpired: true).map((r) => r.id),
        ['fresh', 'expired'],
      );
    });

    test('a newer expired request from a device hides the older one', () {
      final list = [
        _req('older',
            created: now.subtract(const Duration(minutes: 8)), device: 'A'),
        _req('newer',
            created: now.subtract(const Duration(minutes: 6)), device: 'A'),
      ];
      expect(AuthRequest.selectPending(list), isEmpty);
    });
  });
}
