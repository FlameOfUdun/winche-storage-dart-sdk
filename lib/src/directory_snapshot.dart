import 'child_reference.dart';
import 'file_snapshot.dart';

/// An immutable snapshot of a directory listing at a point in time.
///
/// Returned by [ChildReference.listChildren]. Always the authoritative server
/// listing — directory listings are never cached. Each [FileSnapshot] in
/// [files] is annotated with whether this device holds that file's bytes.
final class DirectorySnapshot {
  /// The directory this snapshot lists.
  final ChildReference reference;

  /// One [FileSnapshot] per child file. Unmodifiable.
  final List<FileSnapshot> files;

  /// The sub-folders, as references. Unmodifiable.
  final List<ChildReference> folders;

  /// The next page's token (for `ChildReference.list`), or null on the last page.
  final String? nextPageToken;

  final DateTime timestamp;

  const DirectorySnapshot._({
    required this.reference,
    required this.files,
    required this.timestamp,
    this.folders = const [],
    this.nextPageToken,
  });

  /// A listing snapshot wrapping [files] for [reference].
  factory DirectorySnapshot.fromFiles(
    List<FileSnapshot> files, {
    required ChildReference reference,
    DateTime? timestamp,
    List<ChildReference> folders = const [],
    String? nextPageToken,
  }) =>
      DirectorySnapshot._(
        reference: reference,
        files: List.unmodifiable(files),
        timestamp: timestamp ?? DateTime.now(),
        folders: List.unmodifiable(folders),
        nextPageToken: nextPageToken,
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
