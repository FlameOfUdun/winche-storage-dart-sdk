import 'package:test/test.dart';
import 'package:winche_storage/src/offline/transfer_event.dart';
import 'package:winche_storage/src/offline/transfer_record.dart';

void main() {
  test('TransferRetryConfig has sane defaults', () {
    const c = TransferRetryConfig();
    expect(c.baseDelay, const Duration(seconds: 1));
    expect(c.maxDelay, const Duration(seconds: 30));
    expect(c.maxAttempts, 5);
    expect(c.pollInterval, const Duration(seconds: 30));
  });

  test('TransferEvent carries kind/path/type', () {
    const e = TransferEvent(
      type: TransferEventType.completed,
      kind: TransferKind.download,
      path: 'a/b',
    );
    expect(e.type, TransferEventType.completed);
    expect(e.kind, TransferKind.download);
    expect(e.path, 'a/b');
    expect(e.error, isNull);
  });
}
