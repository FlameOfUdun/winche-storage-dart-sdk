import 'storage_local_store.dart';

/// In-memory [StorageLocalStore]. State is lost when the process exits.
/// Used for tests and the `inMemory: true` configuration.
class MemoryStorageLocalStore implements StorageLocalStore {
  final Map<String, Map<String, Object?>> _catalog = {};
  final Map<int, Map<String, Object?>> _transfers = {};
  final Map<String, Object?> _meta = {};
  int _seq = 0;

  @override
  Future<void> putCatalog(String path, Map<String, Object?> entry) async =>
      _catalog[path] = entry;

  @override
  Future<Map<String, Object?>?> getCatalog(String path) async =>
      _catalog[path];

  @override
  Future<void> removeCatalog(String path) async => _catalog.remove(path);

  @override
  Future<List<Map<String, Object?>>> allCatalog() async =>
      _catalog.values.toList();

  @override
  Future<int> nextTransferSeq() async => ++_seq;

  @override
  Future<void> putTransfer(int seq, Map<String, Object?> record) async =>
      _transfers[seq] = record;

  @override
  Future<List<Map<String, Object?>>> allTransfers() async {
    final seqs = _transfers.keys.toList()..sort();
    return [for (final s in seqs) _transfers[s]!];
  }

  @override
  Future<void> removeTransfer(int seq) async => _transfers.remove(seq);

  @override
  Future<void> putMeta(String key, Object? value) async => _meta[key] = value;

  @override
  Future<Object?> getMeta(String key) async => _meta[key];

  @override
  Future<void> clear() async {
    _catalog.clear();
    _transfers.clear();
    _meta.clear();
    _seq = 0;
  }

  @override
  Future<void> close() async {}
}
