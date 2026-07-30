// Drives the redesigned cache UI through the REAL widgets against a REAL
// server. The point is the annotation path: the listing alone now decides both
// tabs and the per-row badge, so a break there is invisible to unit tests that
// only exercise the SDK.
//
//   dotnet run --launch-profile http   (from samples/Winche.Storage.Sample)
//   flutter test test/e2e_cache_ui_test.dart
//
// ignore_for_file: avoid_print — progress output is the point of this file.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:winche_core/winche_core.dart';
import 'package:winche_storage/winche_storage.dart';
import 'package:winche_storage_example/main.dart';

Future<void> settle(WidgetTester tester,
    {Duration total = const Duration(seconds: 3)}) async {
  final deadline = DateTime.now().add(total);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 50));
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<bool> pumpUntil(
  WidgetTester tester,
  bool Function() test, {
  Duration timeout = const Duration(seconds: 25),
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

/// The list row for [name], if one is on screen.
///
/// Scoped to a ListTile deliberately: the app puts the file path into its
/// SnackBar messages too, so a bare text finder matches the snack and an
/// assertion about the list can pass without the list containing anything.
Finder rowFor(String name) => find.ancestor(
      of: find.textContaining(name),
      matching: find.byType(ListTile),
    );

/// Waits for any SnackBar to auto-dismiss.
///
/// A snack sits at the bottom of the screen over the list, so a row tap made
/// while one is up lands on the snack instead of the row.
Future<void> snacksCleared(WidgetTester tester) async {
  await pumpUntil(tester, () => find.byType(SnackBar).evaluate().isEmpty,
      timeout: const Duration(seconds: 8));
}

/// Opens the overflow menu on the row for [path] and picks [label].
Future<void> rowAction(
    WidgetTester tester, String path, String label) async {
  await snacksCleared(tester);
  final row = rowFor(path);
  expect(row, findsWidgets, reason: 'no row for $path');
  await tester.tap(find.descendant(
      of: row.first, matching: find.byType(PopupMenuButton<String>)));
  await settle(tester, total: const Duration(seconds: 1));
  await tester.tap(find.text(label).last);
  // Only enough to close the menu and let the action start. Callers poll for
  // the outcome: a fixed settle long enough for the network would outlive the
  // SnackBar that reports it.
  await settle(tester, total: const Duration(milliseconds: 800));
}

void main() {
  testWidgets('cache lifecycle through the app UI, against a live server',
      (tester) async {
    await tester.runAsync(() async {
      if (!await serverIsUp()) {
        markTestSkipped('no server on localhost:5209 — start the sample API');
        return;
      }

      // TestWidgetsFlutterBinding installs an HttpOverrides that answers every
      // request with 400 and never touches the network. Without clearing it
      // this suite would "pass" against a stub — which is exactly the failure
      // mode a live test exists to avoid.
      final savedOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = savedOverrides);
      tester.view.physicalSize = const Size(1400, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final dir = Directory.systemTemp
          .createTempSync('winche_cache_ui_e2e')
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

      // Seed a file the UI can act on. file_picker cannot be driven from a
      // test, so the upload itself goes through the SDK — everything after is
      // the app's own widgets.
      final runId = DateTime.now().millisecondsSinceEpoch;
      final name = 'ui_$runId.txt';
      final remote = 'userFiles/${kUsers.first}/$name';
      final src = File('$dir/$name')..writeAsBytesSync([1, 2, 3, 4, 5]);
      await storage.child(remote).uploadPath(src.path).whenDone;
      addTearDown(() async {
        try {
          await storage.child(remote).delete();
        } catch (_) {
          // the test may already have deleted it
        }
      });

      await tester.pumpWidget(StorageExampleApp(auth: auth, storage: storage));
      await settle(tester);

      // 1. The seeded file shows up in the server listing, not yet cached.
      final listed =
          await pumpUntil(tester, () => find.textContaining(name).evaluate().isNotEmpty);
      expect(listed, isTrue, reason: 'the file never appeared in the listing');
      expect(find.textContaining('Cached: false'), findsWidgets,
          reason: 'a file that was never cached is shown as cached');
      print('  [ok] 1. listed from the server, annotated as not cached');

      // 2. The Cached tab is a filter over that same listing, so it is empty.
      await tester.tap(find.text('Cached'));
      await settle(tester, total: const Duration(seconds: 2));
      expect(rowFor(name), findsNothing,
          reason: 'an uncached file appeared in the Cached tab');
      print('  [ok] 2. Cached tab excludes it');

      // 3. Cache it through the app's own menu.
      await tester.tap(find.text('Server'));
      await settle(tester, total: const Duration(seconds: 2));
      await rowAction(tester, name, 'Keep cached');

      final nowCached = await pumpUntil(
          tester, () => find.textContaining('Cached: true').evaluate().isNotEmpty);
      expect(nowCached, isTrue, reason: 'the row never flipped to cached');
      expect(find.byIcon(Icons.offline_pin), findsWidgets,
          reason: 'the cached badge did not appear');
      print('  [ok] 3. keepCached() through the UI flipped the annotation');

      // 4. Which means the Cached tab now includes it — from the same listing,
      //    with no second read.
      await snacksCleared(tester);
      await tester.tap(find.text('Cached'));
      await settle(tester, total: const Duration(seconds: 2));
      expect(rowFor(name), findsWidgets,
          reason: 'a cached file is missing from the Cached tab');
      print('  [ok] 4. Cached tab now includes it');

      // 5. Freshness check against the server.
      await tester.tap(find.text('Server'));
      await settle(tester, total: const Duration(seconds: 2));
      await rowAction(tester, name, 'Check for update');
      final reportedFresh = await pumpUntil(tester,
          () => find.textContaining('upToDate').evaluate().isNotEmpty);
      expect(reportedFresh, isTrue,
          reason: 'checkForUpdate did not report the copy as current');
      print('  [ok] 5. checkForUpdate reports upToDate');

      // 6. Clearing the cached copy leaves the file on the server — the two
      //    are genuinely separate now.
      await rowAction(tester, name, 'Clear cached copy');
      final uncached = await pumpUntil(
          tester, () => find.textContaining('Cached: false').evaluate().isNotEmpty);
      expect(uncached, isTrue, reason: 'the row never flipped back');
      expect(rowFor(name), findsWidgets,
          reason: 'clearing the cache removed the file from the server listing');
      print('  [ok] 6. cleared the copy; the file is still listed');

      // 7. And the Cached tab drops it again.
      await snacksCleared(tester);
      await tester.tap(find.text('Cached'));
      await settle(tester, total: const Duration(seconds: 2));
      expect(rowFor(name), findsNothing);
      print('  [ok] 7. Cached tab excludes it again');

      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester, total: const Duration(seconds: 2));
    });
  }, timeout: const Timeout(Duration(minutes: 5)));
}
