import '../models/download_session.dart';
import '../models/file_data.dart';
import '../models/file_list_page.dart';
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
  /// Registers a file at [path] with the given [mimeType], [sizeBytes], and
  /// optional [metadata], pending its upload: a new one, or a replacement for
  /// the file already there (whose upload then starts over).
  ///
  /// [ifNotExists] only creates (`already-exists` otherwise); [ifVersion] only
  /// replaces the file at that version. [contentDisposition] and
  /// [cacheControl] are sent with the file's downloads.
  Future<FileData> setFile(String path, String mimeType, int sizeBytes,
      {Map<String, dynamic>? metadata,
      bool ifNotExists = false,
      int? ifVersion,
      String? contentDisposition,
      String? cacheControl});

  /// Retrieves the [FileData] for the file at [path], or null if it doesn't exist.
  Future<FileData?> getFile(String path);

  /// Generates an upload URL for the file at [path].
  ///
  /// The file must have already been created with [setFile].
  ///
  /// Throws an error if the file doesn't exist or isn't available for upload.
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
  Future<DownloadSession> generateDownloadUrl(String path);

  /// Confirms that an upload to [path] completed successfully.
  ///
  /// Throws an error if the file doesn't exist or the upload isn't valid.
  Future<FileData> confirmUpload(String path);

  /// Deletes the file at [path] and every file under `path/` (each one
  /// rule-checked; one refusal deletes nothing). [ifVersion] only deletes the
  /// file at that version.
  ///
  /// Returns true if anything was deleted, false if there was nothing there.
  Future<bool> deleteFile(String path, {int? ifVersion});

  /// Merges [metadata] into the file's metadata at [path]: each key is set, and
  /// a null value removes it. [contentDisposition] and [cacheControl] change
  /// those headers (`''` clears one). [ifVersion] only updates the file at that
  /// version. Throws a `StorageNotFoundException` when the file does not exist.
  Future<FileData> updateMetadata(String path, Map<String, dynamic> metadata,
      {int? ifVersion, String? contentDisposition, String? cacheControl});

  /// One page of [directory] (`''` for the top): its files and sub-folders in
  /// name order, at most [maxResults] (server default and cap 1,000), from
  /// [pageToken], optionally only files of [mimeType].
  Future<FileListPage> list(String directory,
      {int? maxResults, String? pageToken, String? mimeType});

  /// Lists all multipart upload parts for the file at [path].
  Future<List<FilePart>> listParts(String path);
}
