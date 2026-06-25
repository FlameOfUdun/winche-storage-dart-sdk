import '../models/file_data.dart';

/// The bridge [TransferController] uses to populate the offline cache for a
/// pinned upload, without depending on [OfflineCatalog] directly. All methods
/// are keyed by the reference path (the upload's durable identity).
abstract interface class UploadPinSink {
  /// Stages [sourceLocalPath] into the cache and returns the staged path.
  Future<String> stageUpload(String path, String sourceLocalPath);

  /// The staged source for [path] if one exists on disk, else null.
  Future<String?> resolveStagedUpload(String path);

  /// Moves the staged copy into the id-keyed cache and records a ready entry.
  Future<void> finalizeUploadPin(String path, FileData confirmed);
}
