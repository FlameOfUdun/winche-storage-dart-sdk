import 'package:test/test.dart';
import 'package:winche_storage/winche_storage.dart';

void main() {
  test('FileData round-trips through toJson/fromJson', () {
    final data = FileData(
      id: 'rec1',
      directory: 'a',
      path: 'a/b.png',
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 2),
      metadata: const {'k': 'v'},
      version: 3,
      mimeType: 'image/png',
      sizeBytes: 42,
      uploadStatus: UploadStatus.complete,
    );

    final restored = FileData.fromJson(data.toJson());

    expect(restored.id, 'rec1');
    expect(restored.path, 'a/b.png');
    expect(restored.createdAt, DateTime.utc(2026, 1, 1));
    expect(restored.updatedAt, DateTime.utc(2026, 1, 2));
    expect(restored.metadata, {'k': 'v'});
    expect(restored.version, 3);
    expect(restored.mimeType, 'image/png');
    expect(restored.sizeBytes, 42);
    expect(restored.uploadStatus, UploadStatus.complete);
  });

  test('contentHash round-trips and defaults to null when absent', () {
    final data = FileData(
      id: 'i', directory: 'd', path: 'a/b',
      createdAt: DateTime.utc(2026, 1, 1), updatedAt: DateTime.utc(2026, 1, 1),
      metadata: const {}, version: 1, mimeType: 'image/png', sizeBytes: 3,
      uploadStatus: UploadStatus.complete, contentHash: 'etag-123',
    );
    expect(FileData.fromJson(data.toJson()).contentHash, 'etag-123');

    final json = Map<String, dynamic>.from(data.toJson())..remove('contentHash');
    expect(FileData.fromJson(json).contentHash, isNull);
  });
}
