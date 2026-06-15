import '../models/download_session.dart';
import '../models/file_data.dart';
import '../models/file_part.dart';
import '../models/upload_session.dart';

/// Abstract interface that callers implement to connect their backend.
///
/// ## IMPORTANT FOR HTTP IMPLEMENTORS
/// All [path] and [directory] parameters are plain slash-separated strings
/// (e.g. `"userFiles/u1/photo.jpg"`). When building URLs for the
/// WincheStorage.REST backend, base64-encode the path segment:
///
/// ```dart
/// import 'dart:convert';
/// final encoded = base64Url.encode(utf8.encode(path));
/// ```
///
/// The REST backend calls `DecodeBase64(path)` on every endpoint.
abstract interface class WincheStorageApi {
  /// Creates a file at [path] with the given [mimeType], [sizeBytes], and optional [metadata].
  ///
  /// Returns the created [FileData].
  Future<FileData> setFile(String path, String mimeType, int sizeBytes,
      {Map<String, dynamic>? metadata});

  /// Retrieves the [FileData] for the file at [path], or null if it doesn't exist.
  Future<FileData?> getFile(String path);

  /// Generates an upload URL for the file at [path].
  ///
  /// The file must have already been created with [setFile].
  ///
  /// Throws an error if the file doesn't exist or isn't available for upload.
  ///
  /// Returns an [UploadSession] containing the URL and any necessary headers.
  Future<UploadSession> generateFileUploadUrl(String path);

  /// Generates an upload URL for a specific multipart upload part.
  ///
  /// The file must have already been created with [setFile].
  ///
  /// Throws an error if the file doesn't exist or isn't available for upload.
  Future<UploadSession> generatePartUploadUrl(String path, int partNumber);

  /// Generates a download URL for the file at [path].
  ///
  /// Throws an error if the file doesn't exist or isn't available for download.
  ///
  /// Returns a [DownloadSession] containing the URL and any necessary headers.
  Future<DownloadSession> generateDownloadUrl(String path);

  /// Confirms that an upload to [path] completed successfully.
  ///
  /// Throws an error if the file doesn't exist or the upload isn't valid.
  ///
  /// Returns the final [FileData] for the uploaded file.
  Future<FileData> confirmUpload(String path);

  /// Deletes the file at [path].
  ///
  /// Returns true if the file was deleted, false if it didn't exist.
  Future<bool> deleteFile(String path);

  /// Updates the metadata for the file at [path]. Throws a
  /// `StorageNotFoundException` when the file does not exist.
  ///
  /// Returns the updated [FileData].
  Future<FileData> updateMetadata(String path, Map<String, dynamic> metadata);

  /// Lists all files in the given [directory], optionally filtering by [mimeType].
  ///
  /// Returns a list of [FileData]s for the files in the directory.
  Future<List<FileData>> listDirectory(String directory, {String? mimeType});

  /// Lists all multipart upload parts for the file at [path].
  Future<List<FilePart>> listParts(String path);
}
