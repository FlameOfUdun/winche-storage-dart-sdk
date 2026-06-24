import 'package:test/test.dart';
import 'package:winche_storage/src/offline/transfer_record.dart';

void main() {
  test('round-trips through toJson/fromJson', () {
    final rec = TransferRecord(
      seq: 7,
      kind: TransferKind.upload,
      path: 'a/b.png',
      localPath: '/src/b.png',
      mimeType: 'image/png',
      metadata: const {'k': 'v'},
      multipartThreshold: 1024,
      status: TransferStatus.running,
      attempt: 0,
      lastError: null,
      createdAt: DateTime.utc(2026, 1, 1),
    );
    final restored = TransferRecord.fromJson(rec.toJson());
    expect(restored.seq, 7);
    expect(restored.kind, TransferKind.upload);
    expect(restored.path, 'a/b.png');
    expect(restored.localPath, '/src/b.png');
    expect(restored.mimeType, 'image/png');
    expect(restored.metadata, {'k': 'v'});
    expect(restored.multipartThreshold, 1024);
    expect(restored.status, TransferStatus.running);
    expect(restored.createdAt, DateTime.utc(2026, 1, 1));
  });

  test('copyWith updates status/attempt/lastError', () {
    final rec = TransferRecord(
      seq: 1,
      kind: TransferKind.download,
      path: 'a/b',
      localPath: '/d/b',
      mimeType: null,
      metadata: null,
      multipartThreshold: null,
      status: TransferStatus.running,
      attempt: 0,
      lastError: null,
      createdAt: DateTime.utc(2026, 1, 1),
    );
    final failed = rec.copyWith(
        status: TransferStatus.failed, attempt: 1, lastError: 'boom');
    expect(failed.status, TransferStatus.failed);
    expect(failed.attempt, 1);
    expect(failed.lastError, 'boom');
    expect(failed.seq, 1);
  });
}
