/// How a cached file compares to the server's current record.
///
/// "Not cached" is deliberately absent: it is `cachedFile() == null`, which is
/// answerable locally without a network call. Every value here is the result of
/// asking the server.
enum CacheStatus {
  /// The cached bytes match the server's current content fingerprint.
  upToDate,

  /// The server's bytes were overwritten since caching. Call `refreshCache()`.
  contentChanged,

  /// The server no longer has a record at this path.
  remoteDeleted,

  /// The server has a record but no bytes — an upload is in flight, or one
  /// failed. There is nothing to compare against yet.
  ///
  /// Distinct from [unknown], which means only "could not ask".
  remoteIncomplete,

  /// The server could not be reached, so the comparison could not be made.
  unknown,
}
