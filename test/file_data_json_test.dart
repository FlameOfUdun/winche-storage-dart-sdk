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
}
