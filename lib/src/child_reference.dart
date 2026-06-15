import 'dart:typed_data';

import 'package:mime/mime.dart';

import 'api/winche_storage_api.dart';
import 'file_snapshot.dart';
import 'tasks/download_task.dart';
import 'tasks/upload_task.dart';

final class ChildReference {
  final String path;
  final WincheStorageApi api;
  final int multipartThreshold;

  /// Resolves the default download directory, or null when none is configured.
  /// Resolved lazily by [DownloadTask] when `saveTo` is omitted.
  final Future<String> Function()? directoryResolver;

  const ChildReference({
    required this.path,
    required this.api,
    this.multipartThreshold = 5 * 1024 * 1024,
    this.directoryResolver,
  });

  /// The last path segment (e.g. `a.png`).
  String get name {
    final i = path.lastIndexOf('/');
    return i < 0 ? path : path.substring(i + 1);
  }

  /// Alias for [path].
  String get fullPath => path;

  /// The parent reference, or null at the root (a single-segment path).
  ChildReference? get parent {
    final i = path.lastIndexOf('/');
    if (i < 0) return null;
    return ChildReference(
      path: path.substring(0, i),
      api: api,
      multipartThreshold: multipartThreshold,
      directoryResolver: directoryResolver,
    );
  }

  /// Returns a new [ChildReference] for a child path.
  ChildReference child(String path) {
    return ChildReference(
      api: api,
      multipartThreshold: multipartThreshold,
      directoryResolver: directoryResolver,
      path: '${this.path}/$path',
    );
  }

  /// Fetches metadata. Returns a non-existent snapshot ([FileSnapshot.exists]
  /// is false) when the file is absent.
  Future<FileSnapshot> get() async {
    final fileData = await api.getFile(path);
    if (fileData == null) return FileSnapshot.missing(this);
    return FileSnapshot.fromData(fileData, reference: this);
  }

  /// Lists the files in the directory at this reference's path.
  ///
  /// Optionally filtered by [mimeType]. Returns a [FileSnapshot] per child file.
  Future<List<FileSnapshot>> list({String? mimeType}) async {
    final files = await api.listDirectory(path, mimeType: mimeType);
    final timestamp = DateTime.now();
    return files.map((file) {
      return FileSnapshot.fromData(
        file,
        timestamp: timestamp,
        reference: ChildReference(
          path: file.path,
          api: api,
          multipartThreshold: multipartThreshold,
          directoryResolver: directoryResolver,
        ),
      );
    }).toList();
  }

  /// Uploads local file.
  ///
  /// [mimeType] is optional — when omitted it is inferred from [localPath]'s
  /// extension via the `mime` package, falling back to `application/octet-stream`.
  UploadTask uploadPath(
    String localPath, {
    String? mimeType,
    Map<String, dynamic>? metadata,
    int? multipartThreshold,
  }) {
    final resolvedMime =
        mimeType ?? lookupMimeType(localPath) ?? 'application/octet-stream';
    return UploadTask.start(
      reference: this,
      localPath: localPath,
      mimeType: resolvedMime,
      metadata: metadata,
      multipartThreshold: multipartThreshold ?? this.multipartThreshold,
    );
  }

  /// Uploads bytes.
  ///
  /// [mimeType] is required when uploading bytes, as it cannot be inferred.
  UploadTask uploadBytes(
    Uint8List bytes,
    String mimeType, {
    Map<String, dynamic>? metadata,
    int? multipartThreshold,
  }) {
    if (mimeType.isEmpty) {
      throw ArgumentError('mimeType is required when uploading bytes.');
    }
    return UploadTask.startFromBytes(
      reference: this,
      bytes: bytes,
      mimeType: mimeType,
      metadata: metadata,
      multipartThreshold: multipartThreshold ?? this.multipartThreshold,
    );
  }

  /// Downloads a file.
  ///
  /// [saveTo] is optional — when omitted, the file is saved to
  /// `<directoryResolver()>/path`, resolved lazily on first use. If no
  /// `directoryResolver` is configured, [saveTo] becomes required (otherwise the
  /// download fails with a [StateError]).
  ///
  /// [extension] overrides the file extension on the resolved save path
  /// (e.g. `'jpg'` or `'.jpg'`). Replaces any existing extension.
  DownloadTask download({String? saveTo, String? extension}) {
    return DownloadTask.start(
      reference: this,
      saveTo: saveTo,
      directoryResolver: directoryResolver,
      extension: extension,
    );
  }

  /// Updates metadata on the server. Throws `StorageNotFoundException` when the
  /// file does not exist.
  Future<FileSnapshot> updateMetadata(Map<String, dynamic> metadata) async {
    final updatedData = await api.updateMetadata(path, metadata);
    return FileSnapshot.fromData(updatedData, reference: this);
  }

  /// Deletes from the server. Returns true if a file was deleted.
  Future<bool> delete() async {
    return await api.deleteFile(path);
  }
}
