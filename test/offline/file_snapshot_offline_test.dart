import 'package:test/test.dart';
import 'package:winche_storage/winche_storage.dart';

import '../support/noop_api.dart';

FileData _data() => FileData(
      id: 'rec1',
      directory: 'a',
      path: 'a/b.png',
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
      metadata: const {},
      version: 1,
      mimeType: 'image/png',
      sizeBytes: 1,
      uploadStatus: UploadStatus.complete,
    );

void main() {
  test('fromData defaults: not from cache, data not cached, no localPath', () {
    final ref = ChildReference(path: 'a/b.png', api: NoopApi());
    final s = FileSnapshot.fromData(_data(), reference: ref);
    expect(s.fromCache, isFalse);
    expect(s.data!.localPath, isNull);
    expect(s.data!.isCached, isFalse);
  });

  test('data can carry localPath and isCached', () {
    final ref = ChildReference(path: 'a/b.png', api: NoopApi());
    final data = _data().copyWith(localPath: '/cache/rec1.png', isCached: true);
    final s = FileSnapshot.fromData(data, reference: ref);
    expect(s.fromCache, isFalse);
    expect(s.data!.localPath, '/cache/rec1.png');
    expect(s.data!.isCached, isTrue);
  });

  test('fromCachedEntry sets fromCache and folds localPath/isCached into data',
      () {
    final ref = ChildReference(path: 'a/b.png', api: NoopApi());
    final entry = CatalogEntry(
      data: _data(),
      localPath: '/cache/rec1.png',
      pinnedAt: DateTime.utc(2026, 1, 2),
      status: CatalogStatus.ready,
    );
    final s = FileSnapshot.fromCachedEntry(entry, reference: ref);
    expect(s.exists, isTrue);
    expect(s.fromCache, isTrue);
    expect(s.data!.localPath, '/cache/rec1.png');
    expect(s.data!.isCached, isTrue);
    expect(s.data!.id, 'rec1');
  });
}
