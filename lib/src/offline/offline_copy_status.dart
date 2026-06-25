/// The freshness of a pinned offline copy relative to the server, as reported by
/// `ChildReference.offlineCopyStatus()`.
enum OfflineCopyStatus {
  /// Nothing is pinned at this path.
  notPinned,

  /// The cached bytes match the current remote content.
  upToDate,

  /// The remote content was overwritten — the cached bytes are stale, so
  /// `refreshOfflineCopy()` should be called to re-download them.
  contentChanged,

  /// The remote file no longer exists.
  remoteDeleted,

  /// Couldn't be determined — the server was unreachable (offline), or no content
  /// fingerprint is available on the cached or remote record (e.g. a file pinned
  /// before content hashing existed).
  unknown,
}
