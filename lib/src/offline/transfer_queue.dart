import 'storage_local_store.dart';
import 'transfer_record.dart';

/// Persisted, seq-ordered queue of in-flight transfers over a
/// [StorageLocalStore].
class TransferQueue {
  TransferQueue(this._store);

  final StorageLocalStore _store;

  /// Reserves a seq, builds the record with it, and persists it.
  Future<int> enqueue(TransferRecord Function(int seq) build) async {
    final seq = await _store.nextTransferSeq();
    await _store.putTransfer(seq, build(seq).toJson());
    return seq;
  }

  Future<List<TransferRecord>> all() async =>
      [for (final j in await _store.allTransfers()) TransferRecord.fromJson(j)];

  Future<TransferRecord?> get(int seq) async {
    for (final r in await all()) {
      if (r.seq == seq) return r;
    }
    return null;
  }

  Future<void> update(TransferRecord record) =>
      _store.putTransfer(record.seq, record.toJson());

  Future<void> remove(int seq) => _store.removeTransfer(seq);

  Future<bool> hasPending() async =>
      (await _store.allTransfers()).isNotEmpty;
}
