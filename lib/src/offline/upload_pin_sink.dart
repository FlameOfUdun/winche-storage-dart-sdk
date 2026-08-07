import '../models/file_data.dart';

/// The bridge [TransferController] uses to populate the file cache for a
/// `cache: true` upload, without depending on [OfflineCatalog] directly. All methods
/// are keyed by the reference path (the upload's durable identity).
abstract interface class UploadPinSink {
  /// Stages [sourceLocalPath] into the cache and returns the staged path.
  Future<String> stageUpload(String path, String sourceLocalPath);

  /// The staged source for [path] if one exists on disk, else null.
  Future<String?> resolveStagedUpload(String path);

  /// Moves the staged copy into the id-keyed cache and records a ready entry.
  ///
  /// Returns the path the bytes now live at, or null when no copy survived to
  /// commit and a deferred entry was recorded instead.
  Future<String?> finalizeUploadPin(String path, FileData confirmed);
}
