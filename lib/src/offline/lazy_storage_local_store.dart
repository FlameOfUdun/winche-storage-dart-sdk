import 'storage_local_store.dart';

/// A [StorageLocalStore] that defers opening its underlying store until the
/// first operation. The [_open] factory is invoked at most once (its Future is
/// memoized), so lazy directory resolution is transparent to callers.
class LazyStorageLocalStore implements StorageLocalStore {
  LazyStorageLocalStore(this._open);

  final Future<StorageLocalStore> Function() _open;
  Future<StorageLocalStore>? _opened;

  Future<StorageLocalStore> _ensure() => _opened ??= _open();

  @override
  Future<void> putCatalog(String path, Map<String, Object?> entry) async =>
      (await _ensure()).putCatalog(path, entry);

  @override
  Future<Map<String, Object?>?> getCatalog(String path) async =>
      (await _ensure()).getCatalog(path);

  @override
  Future<void> removeCatalog(String path) async =>
      (await _ensure()).removeCatalog(path);

  @override
  Future<List<Map<String, Object?>>> allCatalog() async =>
      (await _ensure()).allCatalog();

  @override
  Future<int> nextTransferSeq() async => (await _ensure()).nextTransferSeq();

  @override
  Future<void> putTransfer(int seq, Map<String, Object?> record) async =>
      (await _ensure()).putTransfer(seq, record);

  @override
  Future<List<Map<String, Object?>>> allTransfers() async =>
      (await _ensure()).allTransfers();

  @override
  Future<void> removeTransfer(int seq) async =>
      (await _ensure()).removeTransfer(seq);

  @override
  Future<void> putMeta(String key, Object? value) async =>
      (await _ensure()).putMeta(key, value);

  @override
  Future<Object?> getMeta(String key) async => (await _ensure()).getMeta(key);

  @override
  Future<void> clear() async => (await _ensure()).clear();

  @override
  Future<void> close() async {
    final opened = _opened;
    if (opened == null) return;
    await (await opened).close();
  }
}
