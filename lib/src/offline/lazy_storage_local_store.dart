import 'storage_local_store.dart';

/// A [StorageLocalStore] that defers opening its underlying store until the
/// first operation. The [_open] factory is invoked at most once (its Future is
/// memoized), so lazy directory resolution is transparent to callers.
///
/// After [close], every operation is a silent no-op rather than an error: the
/// backing sembast database throws `database is closed` on any access, and a
/// straggling callback — a transfer unwinding, a fire-and-forget catalog write —
/// would surface that as an unhandled async error the caller cannot catch.
/// "Nothing cached" is the safe reading of a store that is gone.
class LazyStorageLocalStore implements StorageLocalStore {
  LazyStorageLocalStore(this._open);

  final Future<StorageLocalStore> Function() _open;
  Future<StorageLocalStore>? _opened;
  bool _closed = false;

  /// Whether [close] has been called.
  bool get isClosed => _closed;

  Future<StorageLocalStore> _ensure() => _opened ??= _open();

  @override
  Future<void> putCatalog(String path, Map<String, Object?> entry) async {
    if (_closed) return;
    return (await _ensure()).putCatalog(path, entry);
  }

  @override
  Future<Map<String, Object?>?> getCatalog(String path) async {
    if (_closed) return null;
    return (await _ensure()).getCatalog(path);
  }

  @override
  Future<void> removeCatalog(String path) async {
    if (_closed) return;
    return (await _ensure()).removeCatalog(path);
  }

  @override
  Future<List<Map<String, Object?>>> allCatalog() async {
    if (_closed) return const [];
    return (await _ensure()).allCatalog();
  }

  @override
  Future<int> nextTransferSeq() async {
    if (_closed) return 0;
    return (await _ensure()).nextTransferSeq();
  }

  @override
  Future<void> putTransfer(int seq, Map<String, Object?> record) async {
    if (_closed) return;
    return (await _ensure()).putTransfer(seq, record);
  }

  @override
  Future<List<Map<String, Object?>>> allTransfers() async {
    if (_closed) return const [];
    return (await _ensure()).allTransfers();
  }

  @override
  Future<void> removeTransfer(int seq) async {
    if (_closed) return;
    return (await _ensure()).removeTransfer(seq);
  }

  @override
  Future<void> putMeta(String key, Object? value) async {
    if (_closed) return;
    return (await _ensure()).putMeta(key, value);
  }

  @override
  Future<Object?> getMeta(String key) async {
    if (_closed) return null;
    return (await _ensure()).getMeta(key);
  }

  @override
  Future<void> clear() async {
    if (_closed) return;
    return (await _ensure()).clear();
  }

  @override
  Future<void> close() async {
    if (_closed) return; // idempotent
    _closed = true;
    final opened = _opened;
    if (opened == null) return; // never opened — nothing to close
    await (await opened).close();
  }
}
