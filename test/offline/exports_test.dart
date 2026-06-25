import 'package:test/test.dart';
import 'package:winche_storage/winche_storage.dart';

void main() {
  test('public offline types are exported', () {
    expect(MemoryStorageLocalStore(), isA<StorageLocalStore>());
    expect(TransferKind.upload, isA<TransferKind>());
    expect(CatalogStatus.ready, isA<CatalogStatus>());
  });
}
