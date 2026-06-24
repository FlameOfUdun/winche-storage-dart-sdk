import 'package:sembast/sembast_memory.dart';
import 'package:test/test.dart';
import 'package:winche_storage/src/offline/lazy_storage_local_store.dart';
import 'package:winche_storage/src/offline/sembast_storage_local_store.dart';
import 'package:winche_storage/src/offline/storage_local_store.dart';

void main() {
  Future<StorageLocalStore> open() => SembastStorageLocalStore.open(
        'test',
        factory: databaseFactoryMemory, // in-memory sembast, no disk needed
      );

  test('persists catalog and transfers via sembast factory', () async {
    final s = await open();
    await s.putCatalog('a/b', {'x': 1});
    final seq = await s.nextTransferSeq();
    await s.putTransfer(seq, {'seq': seq, 'path': 'a/b'});

    expect(await s.getCatalog('a/b'), {'x': 1});
    expect((await s.allTransfers()).single['path'], 'a/b');
    await s.close();
  });

  test('LazyStorageLocalStore opens underlying store only on first use',
      () async {
    var opened = 0;
    final lazy = LazyStorageLocalStore(() async {
      opened++;
      return open();
    });
    expect(opened, 0);
    await lazy.putMeta('k', 'v');
    expect(opened, 1);
    expect(await lazy.getMeta('k'), 'v');
    await lazy.close();
  });
}
