/// Durable key/value backing store for the offline catalog and transfer queue.
/// All values are JSON-safe (`Map`/`List`/`String`/`num`/`bool`/null).
///
/// Implementations need not be transactional; callers maintain durability
/// invariants by writing the queue before mutating the catalog and replaying
/// idempotently.
abstract interface class StorageLocalStore {
  // --- Catalog (pinned files, keyed by reference path) ---
  Future<void> putCatalog(String path, Map<String, Object?> entry);
  Future<Map<String, Object?>?> getCatalog(String path);
  Future<void> removeCatalog(String path);
  Future<List<Map<String, Object?>>> allCatalog();

  // --- Transfer queue (keyed by monotonic seq) ---
  /// Returns a new, strictly increasing sequence number (persisted).
  Future<int> nextTransferSeq();
  Future<void> putTransfer(int seq, Map<String, Object?> record);

  /// All transfer records ordered by ascending seq.
  Future<List<Map<String, Object?>>> allTransfers();
  Future<void> removeTransfer(int seq);

  // --- Metadata ---
  Future<void> putMeta(String key, Object? value);
  Future<Object?> getMeta(String key);

  // --- Lifecycle ---
  Future<void> clear();
  Future<void> close();
}
