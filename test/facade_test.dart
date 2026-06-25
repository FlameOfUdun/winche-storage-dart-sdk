import 'package:test/test.dart';
import 'package:winche_storage/winche_storage.dart';

import 'support/noop_api.dart';

class _FakeApi extends NoopApi {
  FileData? getResult;
  FileData? updateResult;

  @override
  Future<FileData?> getFile(String path) async => getResult;

  @override
  Future<FileData> updateMetadata(
          String path, Map<String, dynamic> metadata) async =>
      updateResult!;
}

FileData _data() => FileData(
      id: 'rec1',
      directory: 'a',
      path: 'a/b',
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
      metadata: const {},
      version: 1,
      mimeType: 'image/png',
      sizeBytes: 1,
      uploadStatus: UploadStatus.complete,
    );

void main() {
  test('get() returns a missing snapshot when absent', () async {
    final api = _FakeApi()..getResult = null;
    final s = await ChildReference(path: 'a/b', api: api).getSnapshot();
    expect(s.exists, isFalse);
    expect(s.data, isNull);
  });

  test('get() returns an existing snapshot when present', () async {
    final data = _data();
    final api = _FakeApi()..getResult = data;
    final s = await ChildReference(path: 'a/b', api: api).getSnapshot();
    expect(s.exists, isTrue);
    expect(s.data, same(data));
  });

  test('updateMetadata wraps the updated record', () async {
    final data = _data();
    final api = _FakeApi()..updateResult = data;
    final s =
        await ChildReference(path: 'a/b', api: api).updateMetadata({'k': 'v'});
    expect(s.exists, isTrue);
    expect(s.data, same(data));
  });
}
