import 'package:test/test.dart';
import 'package:winche_storage/winche_storage.dart';

FileData _data() => FileData(
      id: 'rec1',
      directory: 'a',
      path: 'a/b.png',
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 2),
      metadata: const {},
      version: 2,
      mimeType: 'image/png',
      sizeBytes: 10,
      uploadStatus: UploadStatus.complete,
    );

void main() {
  test('round-trips through toJson/fromJson', () {
    final entry = CatalogEntry(
      data: _data(),
      localPath: '/cache/rec1.png',
      pinnedAt: DateTime.utc(2026, 1, 3),
      status: CatalogStatus.ready,
    );
    final restored = CatalogEntry.fromJson(entry.toJson());
    expect(restored.path, 'a/b.png');
    expect(restored.id, 'rec1');
    expect(restored.localPath, '/cache/rec1.png');
    expect(restored.pinnedAt, DateTime.utc(2026, 1, 3));
    expect(restored.status, CatalogStatus.ready);
    expect(restored.data.version, 2);
  });

  test('copyWith updates status and data', () {
    final entry = CatalogEntry(
      data: _data(),
      localPath: '/cache/rec1.png',
      pinnedAt: DateTime.utc(2026, 1, 3),
      status: CatalogStatus.downloading,
    );
    final ready = entry.copyWith(status: CatalogStatus.ready);
    expect(ready.status, CatalogStatus.ready);
    expect(ready.localPath, '/cache/rec1.png');
  });
}
