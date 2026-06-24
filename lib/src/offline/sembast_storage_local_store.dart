import 'package:sembast/sembast.dart';

import 'sembast_factory.dart';
import 'storage_local_store.dart';

/// Durable [StorageLocalStore] backed by sembast. Pure Dart; works on native
/// (file) and web (IndexedDB) via the platform-selected factory.
///
/// A single sembast database holds three stores: the offline catalog keyed by
/// reference path, the transfer queue keyed by sequence number, and metadata.
class SembastStorageLocalStore implements StorageLocalStore {
  SembastStorageLocalStore._(this._db);

  final Database _db;

  static final _catalog = StoreRef<String, Map<String, Object?>>('catalog');
  static final _transfers = StoreRef<int, Map<String, Object?>>('transfers');
  static final _meta = StoreRef<String, Object?>('meta');

  static const _seqKey = '__seq__';

  /// Opens (or re-opens after a close) a [SembastStorageLocalStore].
  ///
  /// On native platforms [directory] must be supplied; the database file is
  /// `<directory>/<name>.db`. On the web [directory] is ignored and [name] is
  /// the IndexedDB database name. [factory] is a test seam; production callers
  /// omit it.
  static Future<SembastStorageLocalStore> open(
    String name, {
    String? directory,
    DatabaseFactory? factory,
  }) async {
    final dbFactory = factory ?? sembastFactory();
    final path = directory != null ? '$directory/$name.db' : name;
    final db = await dbFactory.openDatabase(path);
    return SembastStorageLocalStore._(db);
  }

  Map<String, Object?> _castMap(Object? raw) {
    final m = raw as Map;
    return {for (final e in m.entries) e.key as String: _castValue(e.value)};
  }

  Object? _castValue(Object? v) {
    if (v is Map) return _castMap(v);
    if (v is List) return [for (final e in v) _castValue(e)];
    return v;
  }

  @override
  Future<void> putCatalog(String path, Map<String, Object?> entry) =>
      _catalog.record(path).put(_db, entry);

  @override
  Future<Map<String, Object?>?> getCatalog(String path) async {
    final raw = await _catalog.record(path).get(_db);
    return raw == null ? null : _castMap(raw);
  }

  @override
  Future<void> removeCatalog(String path) =>
      _catalog.record(path).delete(_db);

  @override
  Future<List<Map<String, Object?>>> allCatalog() async {
    final records = await _catalog.find(_db);
    return [for (final r in records) _castMap(r.value)];
  }

  @override
  Future<int> nextTransferSeq() async {
    final current = (await _meta.record(_seqKey).get(_db) as int?) ?? 0;
    final next = current + 1;
    await _meta.record(_seqKey).put(_db, next);
    return next;
  }

  @override
  Future<void> putTransfer(int seq, Map<String, Object?> record) =>
      _transfers.record(seq).put(_db, record);

  @override
  Future<List<Map<String, Object?>>> allTransfers() async {
    final records = await _transfers.find(
      _db,
      finder: Finder(sortOrders: [SortOrder(Field.key)]),
    );
    return [for (final r in records) _castMap(r.value)];
  }

  @override
  Future<void> removeTransfer(int seq) =>
      _transfers.record(seq).delete(_db);

  @override
  Future<void> putMeta(String key, Object? value) =>
      _meta.record(key).put(_db, value);

  @override
  Future<Object?> getMeta(String key) => _meta.record(key).get(_db);

  @override
  Future<void> clear() async {
    await _catalog.delete(_db);
    await _transfers.delete(_db);
    await _meta.delete(_db);
  }

  @override
  Future<void> close() => _db.close();
}
