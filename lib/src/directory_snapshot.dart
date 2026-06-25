import 'child_reference.dart';
import 'file_snapshot.dart';

/// An immutable snapshot of a directory listing at a point in time.
///
/// Returned by [ChildReference.list]. Wraps the per-file [FileSnapshot]s in
/// [files] plus directory-level metadata.
///
/// [fromCache] mirrors [FileSnapshot.fromCache]: it is true only when the
/// listing was served from the local offline catalog because the server was
/// unreachable — in which case it is the pinned-only (partial) view of the
/// directory, not the authoritative server listing.
final class DirectorySnapshot {
  /// The directory this snapshot lists.
  final ChildReference reference;

  /// One [FileSnapshot] per child file. Unmodifiable.
  final List<FileSnapshot> files;

  /// When the snapshot was taken.
  final DateTime timestamp;

  /// True when [files] came from the local offline catalog because the server
  /// was unreachable (a partial, pinned-only view). False for an authoritative
  /// server listing.
  final bool fromCache;

  const DirectorySnapshot._({
    required this.reference,
    required this.files,
    required this.timestamp,
    required this.fromCache,
  });

  /// A listing snapshot wrapping [files] for [reference].
  factory DirectorySnapshot.fromFiles(
    List<FileSnapshot> files, {
    required ChildReference reference,
    DateTime? timestamp,
    bool fromCache = false,
  }) =>
      DirectorySnapshot._(
        reference: reference,
        files: List.unmodifiable(files),
        timestamp: timestamp ?? DateTime.now(),
        fromCache: fromCache,
      );

  /// The last path segment of [reference] (e.g. `user-123`).
  String get name {
    final p = reference.path;
    final i = p.lastIndexOf('/');
    return i < 0 ? p : p.substring(i + 1);
  }

  int get length => files.length;
  bool get isEmpty => files.isEmpty;
  bool get isNotEmpty => files.isNotEmpty;
}
