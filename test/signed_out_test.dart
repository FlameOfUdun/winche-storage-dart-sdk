import 'package:test/test.dart';
import 'package:winche_core/winche_core.dart';
import 'package:winche_storage/winche_storage.dart';

void main() {
  WincheApp app() => WincheApp('storage-signed-out-${DateTime.now().microsecondsSinceEpoch}',
      // Refused fast: these tests only care how far a call gets.
      options: WincheOptions(endpoints: {'storage': Uri.parse('http://localhost:1/files')}));

  test('off by default: signed out is unbound', () async {
    final a = app();
    final storage = WincheStorage(a)..settings = const WincheStorageSettings(inMemory: true);
    await expectLater(storage.child('public/a.txt').getSnapshot(), throwsA(isA<WincheUnboundException>()));
    await a.dispose();
  });

  test('allowSignedOut: calls go to the server, with no auth service at all', () async {
    final a = app();
    final storage = WincheStorage(a)..settings = const WincheStorageSettings(allowSignedOut: true);
    // Bound and sent: what fails now is the network, not the missing user.
    await expectLater(storage.child('public/a.txt').getSnapshot(), throwsA(isNot(isA<WincheUnboundException>())));
    await a.dispose();
  });
}
