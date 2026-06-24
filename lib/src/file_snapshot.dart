import 'child_reference.dart';
import 'models/file_data.dart';
import 'offline/catalog_entry.dart';

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

  /// True when [data] was served from the local offline catalog because the
  /// server was unreachable. False for an authoritative server response.
  ///
  /// This describes how the *metadata* was obtained. Whether the file's
  /// *content* is downloaded locally is `data.isCached` (with `data.localPath`).
  final bool fromCache;

  const FileSnapshot._({
    required this.reference,
    required this.exists,
    required this.timestamp,
    required this.data,
    required this.fromCache,
  });

  /// A present snapshot wrapping [data].
  factory FileSnapshot.fromData(
    FileData data, {
    required ChildReference reference,
    DateTime? timestamp,
    bool fromCache = false,
  }) =>
      FileSnapshot._(
        reference: reference,
        exists: true,
        timestamp: timestamp ?? DateTime.now(),
        data: data,
        fromCache: fromCache,
      );

  /// A present snapshot built from a cached [entry] (server unreachable). The
  /// entry's local-copy info is folded into [data] (`localPath` + `isCached`).
  factory FileSnapshot.fromCachedEntry(
    CatalogEntry entry, {
    required ChildReference reference,
    DateTime? timestamp,
  }) =>
      FileSnapshot._(
        reference: reference,
        exists: true,
        timestamp: timestamp ?? DateTime.now(),
        data: entry.data
            .copyWith(localPath: entry.localPath, isCached: entry.isCached),
        fromCache: true,
      );

  /// A non-existent snapshot for [reference].
  factory FileSnapshot.missing(ChildReference reference) => FileSnapshot._(
        reference: reference,
        exists: false,
        timestamp: DateTime.now(),
        data: null,
        fromCache: false,
      );

  /// The last path segment (e.g. `a.png`).
  String get name {
    final p = reference.path;
    final i = p.lastIndexOf('/');
    return i < 0 ? p : p.substring(i + 1);
  }
}
