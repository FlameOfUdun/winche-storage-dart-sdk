import '../child_reference.dart';
import '../models/file_data.dart';

/// A file whose bytes are on this device.
///
/// Handed out only when the content is complete and usable: [localPath] always
/// points at a file that exists and is the full [FileData.sizeBytes]. There is
/// deliberately no `isCached` flag — the existence of this object *is* the
/// answer, which is why [ChildReference.cachedFile] returns `CachedFile?`
/// rather than a snapshot that has to be interrogated.
final class CachedFile {
  /// A reference to this file, wired for cache operations — `clearCache()`,
  /// `refreshCache()` and `checkForUpdate()` all work on it, and `delete()`
  /// evicts the local copy along with the remote one.
  ///
  /// It carries no upload queue, so `resumeUpload()` throws on it and
  /// `delete()` will not cancel a queued upload for this path. Use
  /// `storage.child(path)` when either matters.
  final ChildReference reference;

  /// The server record captured when the file was cached.
  ///
  /// May be older than the server's current record — the bytes on disk are a
  /// point-in-time copy. [ChildReference.checkForUpdate] compares the two.
  final FileData data;

  /// Absolute path to the bytes on this device.
  final String localPath;

  final DateTime cachedAt;

  const CachedFile({
    required this.reference,
    required this.data,
    required this.localPath,
    required this.cachedAt,
  });

  /// The storage path this copy is for (e.g. `userFiles/u1/a.png`).
  String get path => reference.path;

  /// The last path segment (e.g. `a.png`).
  String get name => reference.name;
}
