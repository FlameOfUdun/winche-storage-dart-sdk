import 'package:test/test.dart';
import 'package:winche_storage/src/offline/memory_storage_local_store.dart';

void main() {
  test('catalog put/get/remove/all', () async {
    final s = MemoryStorageLocalStore();
    await s.putCatalog('a/b', {'x': 1});
    expect(await s.getCatalog('a/b'), {'x': 1});
    expect(await s.allCatalog(), [
      {'x': 1}
    ]);
    await s.removeCatalog('a/b');
    expect(await s.getCatalog('a/b'), isNull);
    expect(await s.allCatalog(), isEmpty);
  });

  test('transfer seq is strictly increasing and survives ordering', () async {
    final s = MemoryStorageLocalStore();
    final s1 = await s.nextTransferSeq();
    final s2 = await s.nextTransferSeq();
    expect(s2, greaterThan(s1));
    await s.putTransfer(s2, {'seq': s2});
    await s.putTransfer(s1, {'seq': s1});
    final all = await s.allTransfers();
    expect(all.map((e) => e['seq']), [s1, s2]); // ascending by seq
    await s.removeTransfer(s1);
    expect((await s.allTransfers()).map((e) => e['seq']), [s2]);
  });

  test('clear resets everything including seq', () async {
    final s = MemoryStorageLocalStore();
    await s.nextTransferSeq();
    await s.putCatalog('a', {'k': 'v'});
    await s.putMeta('m', 1);
    await s.clear();
    expect(await s.allCatalog(), isEmpty);
    expect(await s.allTransfers(), isEmpty);
    expect(await s.getMeta('m'), isNull);
    expect(await s.nextTransferSeq(), 1);
  });
}
