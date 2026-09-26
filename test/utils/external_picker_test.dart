import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/utils/external_picker.dart';

void main() {
  test('flag is set only while a picker call is in flight, even on error',
      () async {
    expect(externalPickerActive, isFalse);
    final result = await runExternalPicker(() async {
      expect(externalPickerActive, isTrue);
      final nested = await runExternalPicker(() async => 2);
      expect(externalPickerActive, isTrue, reason: 'outer still open');
      return nested + 1;
    });
    expect(result, 3);
    expect(externalPickerActive, isFalse);

    await expectLater(
      runExternalPicker<void>(() async => throw StateError('cancelled')),
      throwsStateError,
    );
    expect(externalPickerActive, isFalse);
    expect(externalPickerDepth.value, 0);
  });
}
