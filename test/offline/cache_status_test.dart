import 'package:test/test.dart';
import 'package:winche_storage/winche_storage.dart';

void main() {
  test('CacheStatus is exported with the expected values', () {
    // `notPinned` deliberately absent: "not cached" is `cachedFile() == null`,
    // answerable locally without a round-trip, so it never belonged in the
    // result of a method that asks the server.
    //
    // `remoteIncomplete` present: the server reporting a record with no bytes
    // used to collapse into `unknown` alongside "could not reach the server".
    expect(CacheStatus.values, [
      CacheStatus.upToDate,
      CacheStatus.contentChanged,
      CacheStatus.remoteDeleted,
      CacheStatus.remoteIncomplete,
      CacheStatus.unknown,
    ]);
  });
}
