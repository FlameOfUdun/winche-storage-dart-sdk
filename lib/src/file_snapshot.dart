import 'child_reference.dart';
import 'models/file_data.dart';

/// An immutable snapshot of a file's server record at a point in time.
///
/// Always a server read — `winche_storage` caches file *content*, never
/// metadata, so there is no second source a snapshot could have come from.
/// What this device holds is reported by [isCached] / [localPath].
final class FileSnapshot {
  final ChildReference reference;
  final bool exists;
  final DateTime timestamp;

  /// The server record, or null when [exists] is false.
  final FileData? data;

  /// True when this device has complete bytes for this file.
  ///
  /// Advisory: read from the catalog row, so a listing costs one bulk read
  /// rather than a filesystem check per file. For an authoritative answer — and
  /// a path guaranteed to open — use [ChildReference.cachedFile].
  final bool isCached;

  /// Absolute path to the local bytes when [isCached], else null.
  final String? localPath;

  const FileSnapshot._({
    required this.reference,
    required this.exists,
    required this.timestamp,
    required this.data,
    required this.isCached,
    required this.localPath,
  });

  /// A present snapshot wrapping [data], optionally annotated with this
  /// device's cache state.
  factory FileSnapshot.fromData(
    FileData data, {
    required ChildReference reference,
    DateTime? timestamp,
    bool isCached = false,
    String? localPath,
  }) =>
      FileSnapshot._(
        reference: reference,
        exists: true,
        timestamp: timestamp ?? DateTime.now(),
        data: data,
        isCached: isCached,
        localPath: localPath,
      );

  /// A non-existent snapshot for [reference].
  factory FileSnapshot.missing(ChildReference reference) => FileSnapshot._(
        reference: reference,
        exists: false,
        timestamp: DateTime.now(),
        data: null,
        isCached: false,
        localPath: null,
      );

  /// The last path segment (e.g. `a.png`).
  String get name {
    final p = reference.path;
    final i = p.lastIndexOf('/');
    return i < 0 ? p : p.substring(i + 1);
  }
}
