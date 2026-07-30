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

  /// When the snapshot was taken.
  final DateTime timestamp;

  const DirectorySnapshot._({
    required this.reference,
    required this.files,
    required this.timestamp,
  });

  /// A listing snapshot wrapping [files] for [reference].
  factory DirectorySnapshot.fromFiles(
    List<FileSnapshot> files, {
    required ChildReference reference,
    DateTime? timestamp,
  }) =>
      DirectorySnapshot._(
        reference: reference,
        files: List.unmodifiable(files),
        timestamp: timestamp ?? DateTime.now(),
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
