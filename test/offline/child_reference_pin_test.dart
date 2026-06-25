import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winche_storage/src/offline/local_paths.dart';
import 'package:winche_storage/src/offline/offline_catalog.dart';
import 'package:winche_storage/winche_storage.dart';

import '../support/noop_api.dart';

/// getFile throws (network down) so the upload fails fast *after* staging — we
/// assert the staged file exists, proving ChildReference wired stageSource.
class _OfflineApi extends NoopApi {
  @override
  Future<FileData?> getFile(String path) async => throw StateError('offline');
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('winche-cr-pin'));
  tearDown(() => tmp.deleteSync(recursive: true));

  OfflineCatalog cat(WincheStorageApi api) => OfflineCatalog(
        api: api,
        store: MemoryStorageLocalStore(),
        directoryResolver: () async => tmp.path,
        multipartThreshold: 5 * 1024 * 1024,
      );

  test('uploadBytes(makeAvailableOffline: true) stages bytes before uploading',
      () async {
    final api = _OfflineApi();
    final ref = ChildReference(path: 'a/b.png', api: api, catalog: cat(api));

    final task = ref.uploadBytes(Uint8List.fromList([7, 7, 7]), 'image/png',
        makeAvailableOffline: true);
    await task.whenDone.catchError((_) => null);

    final staged = stagingFilePath(tmp.path, 'a/b.png');
    expect(File(staged).existsSync(), isTrue);
    expect(File(staged).readAsBytesSync(), [7, 7, 7]);
  });

  test('offline upload with no catalog is a no-op (does not throw)', () async {
    final api = _OfflineApi();
    final ref = ChildReference(path: 'a/b.png', api: api); // catalog == null

    final task = ref.uploadBytes(Uint8List.fromList([1]), 'image/png',
        makeAvailableOffline: true);
    await task.whenDone.catchError((_) => null);

    expect(Directory(p.join(tmp.path, '.staging')).existsSync(), isFalse);
  });
}
