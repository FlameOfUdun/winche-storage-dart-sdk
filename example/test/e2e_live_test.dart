// End-to-end driver for the example app, against a live server.
//
// Drives the REAL widgets against a REAL server — no fakes. `runAsync` is what
// makes that possible: the default fake-async zone freezes the HTTP client's
// timers, so nothing would ever arrive.
//
// Skips itself when no server is listening, so it is safe to run always:
//
//   dotnet run --launch-profile http   (from samples/Winche.Storage.Sample)
//   flutter test
//
// ignore_for_file: avoid_print — progress output is the point of this file;
// when a step fails you want to see how far it got.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:winche_core/winche_core.dart';
import 'package:winche_storage/winche_storage.dart';
import 'package:winche_storage_example/main.dart';

/// Pumps for real wall-clock time so live frames can land.
Future<void> settle(WidgetTester tester,
    {Duration total = const Duration(seconds: 3)}) async {
  final deadline = DateTime.now().add(total);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 50));
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// Pumps until [test] passes or the deadline expires, so a failure reports
/// what was expected rather than a bare timeout.
Future<bool> pumpUntil(
  WidgetTester tester,
  bool Function() test, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (test()) return true;
    await tester.pump(const Duration(milliseconds: 50));
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return test();
}

Future<bool> serverIsUp() async {
  try {
    final socket = await Socket.connect('localhost', 5209,
        timeout: const Duration(seconds: 2));
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  testWidgets('example app multi-user flow against a live server',
      (tester) async {
    await tester.runAsync(() async {
      if (!await serverIsUp()) {
        markTestSkipped(
          'no server on localhost:5209 — start the sample API first: '
          'dotnet run --launch-profile http',
        );
        return;
      }
      // TestWidgetsFlutterBinding installs an HttpOverrides that answers every
      // request with 400 and never touches the network. This suite's assertions
      // are about identity binding, which needs no HTTP -- but leaving the stub
      // in place means the listings behind them are quietly failing, so the
      // "live" in the file name would be a lie.
      final savedOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = savedOverrides);

      tester.view.physicalSize = const Size(1400, 2200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      // A private store directory: path_provider's platform channel does not
      // exist under `flutter test`, so the app's own resolver would throw, and
      // a running app already owns its sembast files.
      final dir = Directory.systemTemp
          .createTempSync('winche_storage_e2e')
          .path
          .replaceAll(r'\', '/');
      addTearDown(() {
        try {
          Directory(dir).deleteSync(recursive: true);
        } catch (_) {
          // Best effort: the store may still hold a handle on Windows.
        }
      });

      Winche.initializeApp(
        options: WincheOptions(
          storageEndpoint: Uri.parse('http://localhost:5209/files'),
          directoryResolver: () async => dir,
        ),
      );
      addTearDown(() async => Winche.deinitializeApp());

      final auth = DemoAuth(Winche.app);
      final storage = WincheStorage.instance;
      auth.signIn(kUsers.first);
      await Winche.app.settled;

      // The app's own root widget, not a stand-in — a copy of the UI here
      // would test the copy.
      await tester.pumpWidget(StorageExampleApp(auth: auth, storage: storage));
      await settle(tester);

      // 1. Signed in as alice, scoped to her directory.
      final asAlice = await pumpUntil(
          tester, () => find.textContaining('alice').evaluate().isNotEmpty);
      expect(asAlice, isTrue, reason: 'never rendered as alice');
      expect(find.text('Signed out'), findsNothing);
      print('  [ok] 1. signed in as alice');

      // 2. Switch to bob through the app's own menu.
      await tester.tap(find.byIcon(Icons.person));
      await settle(tester, total: const Duration(seconds: 1));
      await tester.tap(find.text('bob').last);
      await settle(tester, total: const Duration(seconds: 4));

      final asBob = await pumpUntil(
          tester, () => find.textContaining('bob').evaluate().isNotEmpty);
      expect(asBob, isTrue, reason: 'switching to bob did not rebind the UI');
      print('  [ok] 2. switched to bob; storage rebound to his identity');

      // 3. Sign out — storage must unbind and the app must say so.
      await tester.tap(find.byIcon(Icons.person));
      await settle(tester, total: const Duration(seconds: 1));
      await tester.tap(find.text('Sign out'));
      await settle(tester, total: const Duration(seconds: 3));

      final signedOut = await pumpUntil(
          tester, () => find.text('Signed out').evaluate().isNotEmpty);
      expect(signedOut, isTrue, reason: 'sign-out did not reach the UI');
      expect(storage.debugSession, isNull,
          reason: 'the UI says signed out but storage is still bound');
      print('  [ok] 3. signed out; storage unbound');

      // 4. Sign back in from the signed-out view.
      await tester.tap(find.text('Sign in as alice'));
      await settle(tester, total: const Duration(seconds: 4));
      final reboundIn = await pumpUntil(
          tester, () => find.textContaining('alice').evaluate().isNotEmpty);
      expect(reboundIn, isTrue, reason: 'could not sign back in');
      expect(storage.debugSession, isNotNull);
      print('  [ok] 4. signed back in; a new session bound');

      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester, total: const Duration(seconds: 2));
    });
  }, timeout: const Timeout(Duration(minutes: 5)));
}

