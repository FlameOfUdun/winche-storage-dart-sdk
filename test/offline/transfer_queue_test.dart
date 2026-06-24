import 'package:test/test.dart';
import 'package:winche_storage/src/offline/memory_storage_local_store.dart';
import 'package:winche_storage/src/offline/transfer_queue.dart';
import 'package:winche_storage/src/offline/transfer_record.dart';

void main() {
  TransferRecord rec(int seq, TransferKind kind, String path) => TransferRecord(
        seq: seq,
        kind: kind,
        path: path,
        localPath: '/d/$path',
        mimeType: null,
        metadata: null,
        multipartThreshold: null,
        status: TransferStatus.running,
        attempt: 0,
        lastError: null,
        createdAt: DateTime.utc(2026, 1, 1),
      );

  test('enqueue assigns increasing seq and persists', () async {
    final q = TransferQueue(MemoryStorageLocalStore());
    final s1 = await q.enqueue(
        (seq) => rec(seq, TransferKind.download, 'a'));
    final s2 = await q.enqueue(
        (seq) => rec(seq, TransferKind.upload, 'b'));
    expect(s2, greaterThan(s1));
    final all = await q.all();
    expect(all.map((r) => r.path), ['a', 'b']);
    expect(await q.hasPending(), isTrue);
  });

  test('get / update / remove', () async {
    final q = TransferQueue(MemoryStorageLocalStore());
    final s = await q.enqueue((seq) => rec(seq, TransferKind.download, 'a'));
    final got = await q.get(s);
    expect(got!.path, 'a');
    await q.update(got.copyWith(status: TransferStatus.failed, attempt: 2));
    expect((await q.get(s))!.attempt, 2);
    await q.remove(s);
    expect(await q.get(s), isNull);
    expect(await q.hasPending(), isFalse);
  });
}
