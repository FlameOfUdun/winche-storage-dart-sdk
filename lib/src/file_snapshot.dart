import 'child_reference.dart';
import 'models/file_data.dart';

/// An immutable snapshot of a file's metadata at a point in time.
///
/// Mirrors the ergonomics of `winche_database`'s `DocumentSnapshot`: [exists]
/// is false when the file is not present (then [data] is null).
final class FileSnapshot {
  final ChildReference reference;
  final bool exists;
  final DateTime timestamp;

  /// The file record, or null when [exists] is false.
  final FileData? data;

  const FileSnapshot._({
    required this.reference,
    required this.exists,
    required this.timestamp,
    required this.data,
  });

  /// A present snapshot wrapping [data].
  factory FileSnapshot.fromData(
    FileData data, {
    required ChildReference reference,
    DateTime? timestamp,
  }) =>
      FileSnapshot._(
        reference: reference,
        exists: true,
        timestamp: timestamp ?? DateTime.now(),
        data: data,
      );

  /// A non-existent snapshot for [reference].
  factory FileSnapshot.missing(ChildReference reference) => FileSnapshot._(
        reference: reference,
        exists: false,
        timestamp: DateTime.now(),
        data: null,
      );

  /// The last path segment (e.g. `a.png`).
  String get name {
    final p = reference.path;
    final i = p.lastIndexOf('/');
    return i < 0 ? p : p.substring(i + 1);
  }

  /// The full path (= `reference.path`).
  String get path => reference.path;

  /// Alias for [reference].
  ChildReference get ref => reference;
}
