// Against a running emulator whose storage rules allow signed-out reads under public/:
//   dart run tool/signed_out_live.dart <token from `winche emulators token u1`> [host:port]
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:winche_core/winche_core.dart';
import 'package:winche_storage/winche_storage.dart';

final class _TokenAuth extends WincheService with WincheIdentitySource {
  _TokenAuth(super.app, this.token) {
    notifyIdentityChanged(activeIdentity);
  }
  final String token;
  @override
  WincheIdentity? get activeIdentity => WincheIdentity('u1');
  @override
  Future<String?> getAuthToken({bool forceRefresh = false}) async => token;
}

Future<void> main(List<String> args) async {
  final target = args.length > 1 ? args[1] : 'localhost:9090';
  final options = WincheOptions(endpoints: {'storage': Uri.parse('http://$target/files/v1')});

  // Signed in: put a public file.
  final writer = WincheApp('writer', options: options);
  _TokenAuth(writer, args.first);
  final signedIn = WincheStorage(writer)..settings = const WincheStorageSettings(inMemory: true);
  await writer.settled;
  await signedIn.child('public/hello.txt').uploadBytes(Uint8List.fromList(utf8.encode('hello, signed-out world')), 'text/plain').whenDone;
  stdout.writeln('signed-in upload public/hello.txt: done');
  await writer.dispose();

  // Signed out, no auth service: read it back.
  final reader = WincheApp('reader', options: options);
  final storage = WincheStorage(reader)..settings = const WincheStorageSettings(allowSignedOut: true, inMemory: true);
  final snapshot = await storage.child('public/hello.txt').getSnapshot();
  stdout.writeln('signed-out snapshot: exists=${snapshot.exists} size=${snapshot.data?.sizeBytes}');
  final file = '${Directory.systemTemp.createTempSync('winche-').path}/hello.txt';
  await storage.child('public/hello.txt').download(file).whenDone;
  stdout.writeln('signed-out download: "${File(file).readAsStringSync()}"');
  try {
    await storage.child('private/x.txt').getSnapshot();
    stdout.writeln('signed-out read private/x.txt: allowed (unexpected)');
  } on WincheException catch (e) {
    stdout.writeln('signed-out read private/x.txt: refused (${e.runtimeType})');
  }
  await reader.dispose();
}
