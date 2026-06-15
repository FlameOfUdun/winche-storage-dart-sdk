import 'package:winche_storage/winche_storage.dart';

/// A [WincheStorageApi] whose methods throw unless overridden. Subclass and
/// override the few methods a test needs.
class NoopApi implements WincheStorageApi {
  @override
  Future<FileData> setFile(String path, String mimeType, int sizeBytes,
          {Map<String, dynamic>? metadata}) =>
      throw UnimplementedError();
  @override
  Future<FileData?> getFile(String path) => throw UnimplementedError();
  @override
  Future<UploadSession> generateFileUploadUrl(String path) =>
      throw UnimplementedError();
  @override
  Future<UploadSession> generatePartUploadUrl(String path, int partNumber) =>
      throw UnimplementedError();
  @override
  Future<DownloadSession> generateDownloadUrl(String path) =>
      throw UnimplementedError();
  @override
  Future<FileData> confirmUpload(String path) => throw UnimplementedError();
  @override
  Future<bool> deleteFile(String path) => throw UnimplementedError();
  @override
  Future<FileData> updateMetadata(String path, Map<String, dynamic> metadata) =>
      throw UnimplementedError();
  @override
  Future<List<FileData>> listDirectory(String directory, {String? mimeType}) =>
      throw UnimplementedError();
  @override
  Future<List<FilePart>> listParts(String path) => throw UnimplementedError();
}
