import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:winche_core/winche_core.dart';
import 'package:winche_storage/winche_storage.dart';
import 'package:file_picker/file_picker.dart';

/// Stands in for a real auth package. A production app uses one that talks to
/// its backend; all this SDK needs is an identity announced to core.
final class DemoAuth extends WincheAuthService {
  DemoAuth(super.app);

  WincheIdentity? _identity;

  @override
  WincheIdentity? get activeIdentity => _identity;

  @override
  Future<String?> getAuthToken({bool forceRefresh = false}) async =>
      _identity?.id;

  void signIn(String id) {
    _identity = WincheIdentity(id);
    notifyIdentityChanged(_identity);
  }

  void signOut() {
    _identity = null;
    notifyIdentityChanged(null);
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  Winche.initializeApp(
    options: WincheOptions(
      storageEndpoint: Uri.parse('http://localhost:5209/files'),
      // Enables both the durable transfer queue (auto-resume) and the offline
      // cache. Every Winche package creates its state under this one root,
      // each in a subdirectory scoped to the signed-in identity.
      directoryResolver: () async {
        final dir = await getApplicationDocumentsDirectory();
        return p.join(dir.path, 'winche_files');
      },
    ),
  );

  final auth = DemoAuth(Winche.app);
  final storage = WincheStorage.instance;

  // Binding is core's job: this announces an identity and core builds the
  // session storage runs on. Switching users is another signIn — the previous
  // identity's store is torn down first, and their queued transfers stay on
  // disk for when they come back.
  auth.signIn(kUsers.first);

  runApp(StorageExampleApp(auth: auth, storage: storage));
}

/// The demo identities. The sample server takes the bearer token verbatim as
/// the uid, so these are both the token and the rule subject: `alice` can only
/// touch `userFiles/alice`.
const kUsers = ['alice', 'bob'];

class StorageExampleApp extends StatefulWidget {
  final DemoAuth auth;
  final WincheStorage storage;

  const StorageExampleApp({super.key, required this.auth, required this.storage});

  @override
  State<StorageExampleApp> createState() => _StorageExampleAppState();
}

class _StorageExampleAppState extends State<StorageExampleApp> {
  String? _uid = kUsers.first;

  Future<void> _switchTo(String? uid) async {
    // Clear the uid BEFORE announcing, so no descendant rebuilds against
    // storage that core is midway through unbinding.
    setState(() => _uid = uid);
    if (uid == null) {
      widget.auth.signOut();
    } else {
      widget.auth.signIn(uid);
    }
    // Core awaits every service's hook, so this resolves only once the
    // outgoing store is closed and the incoming one is built.
    await Winche.app.settled;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final uid = _uid;
    return MaterialApp(
      home: uid == null
          ? _SignedOutPage(onSignIn: _switchTo)
          : _HomePage(
              // Keyed by uid so a switch rebuilds the page from scratch rather
              // than leaving one user's listing on screen under another's name.
              key: ValueKey(uid),
              storage: widget.storage,
              uid: uid,
              onSwitchUser: _switchTo,
            ),
    );
  }
}

class _SignedOutPage extends StatelessWidget {
  final Future<void> Function(String?) onSignIn;

  const _SignedOutPage({required this.onSignIn});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Winche Storage Example')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline, size: 48),
            const SizedBox(height: 12),
            const Text('Signed out'),
            const SizedBox(height: 4),
            const Text(
              'Storage is unbound: there is no session to serve requests,\n'
              'and no store open on disk.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            for (final u in kUsers)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: FilledButton(
                  onPressed: () => onSignIn(u),
                  child: Text('Sign in as $u'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _HomePage extends StatefulWidget {
  final WincheStorage storage;
  final String uid;
  final Future<void> Function(String?) onSwitchUser;

  const _HomePage({
    super.key,
    required this.storage,
    required this.uid,
    required this.onSwitchUser,
  });

  @override
  State<_HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<_HomePage>
    with SingleTickerProviderStateMixin {
  WincheStorage get storage => widget.storage;

  /// Scoped to the signed-in user, which is what the sample server's rules
  /// enforce: `alice` is denied everything outside `userFiles/alice`.
  ChildReference get root => storage.child('userFiles/${widget.uid}');

  UploadTask? currentUploadTask;
  DownloadTask? currentDownloadTask;

  /// When on, uploads are also cached locally (`cache: true`) — staged and
  /// placed straight into the file cache, no separate download roundtrip.
  bool cacheUploads = false;

  /// When on, file uploads are durable (`enqueue: true`) — queued, retried, and
  /// resumed after a restart, so they appear in the pending-transfers panel.
  bool queueUploads = true;

  /// The current directory listing. Each file carries its own `isCached`, so
  /// one read backs both tabs — no second cache-only listing to cross-reference.
  /// Refreshed via [_reload].
  late Future<DirectorySnapshot> _listing;

  /// Switches the file view between all files and the cached subset.
  late final TabController _tabController;

  /// Recent auto-resume transfer events (most recent first, capped).
  final List<TransferEvent> _events = [];
  bool _eventsExpanded = false;
  StreamSubscription<TransferEvent>? _eventsSub;

  /// Snapshot of the durable transfer queue (`storage.pendingUploads()`).
  List<TransferRecord> _pending = const [];
  bool _pendingExpanded = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _listing = _loadListing();
    _loadPending();

    // Observe the durable transfer queue as it drains (auto-resume).
    //
    // Guarded because this page can be built while storage is unbound — during
    // a sign-out, or between a switch tearing one session down and the next
    // being built. `transferEvents` needs a session; without the guard it
    // throws out of initState, which Flutter turns into a red screen.
    try {
      _eventsSub = storage.transferEvents.listen((event) {
        if (!mounted) return;
        setState(() {
          _events.insert(0, event);
          if (_events.length > 10) _events.removeLast();
        });
        _loadPending(); // the queue changed — refresh the snapshot
      });
    } on WincheUnboundException {
      // Nobody is signed in; there is no queue to observe yet.
    } on StateError {
      // No local store configured, so there is no durable queue at all.
    }
  }

  DirectorySnapshot _emptyListing() => DirectorySnapshot.fromFiles(
        const [],
        reference: root,
        timestamp: DateTime.now(),
      );

  @override
  void dispose() {
    _eventsSub?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  void _reload() {
    // A block body, not an arrow: `setState(() => _listing = _loadListing())`
    // returns the assigned Future, and Flutter asserts that a setState callback
    // returns nothing. The assignment would still land, so the failure shows up
    // only as a list that doesn't repaint until something else rebuilds it.
    setState(() {
      _listing = _loadListing();
    });
  }

  /// Loads the server listing. Each returned file is already annotated with
  /// whether this device has its bytes, so there is no second cache-only read
  /// and no set of paths to cross-reference.
  ///
  /// Listings are never cached, so there is no offline fallback: when the
  /// server is unreachable the error surfaces and the FutureBuilder renders it.
  Future<DirectorySnapshot> _loadListing() async {
    try {
      return await root.listChildren();
    } on WincheUnboundException {
      // A sign-out landed while this was in flight. The page is being replaced
      // by the signed-out view, so there is nobody left to show a listing to —
      // and letting it escape makes it an unhandled async error rather than
      // something a FutureBuilder could render.
      return _emptyListing();
    }
  }

  /// Loads the durable upload-queue snapshot via `pendingUploads()`.
  Future<void> _loadPending() async {
    try {
      final pending = await storage.pendingUploads();
      if (mounted) setState(() => _pending = pending);
    } catch (_) {
      // No store configured — leave the snapshot empty.
    }
  }

  /// Reattaches a queued upload's live handle to the progress banner — e.g.
  /// after a restart, when the original task object is gone but the durable
  /// upload is still resuming.
  ///
  /// Uploads only: the queue holds nothing else. A download that did not
  /// survive the process is not running, so there is nothing to reattach to —
  /// `storage.downloadFor(path)` covers the in-session case instead.
  void _reattach(TransferRecord rec) {
    try {
      final t = storage.uploadFor(rec.path);
      if (t == null) {
        _snack('No live upload for ${rec.path}');
        return;
      }
      setState(() => currentUploadTask = t);
      _snack('Reattached: ${rec.path}');
    } catch (e) {
      _snack('Reattach failed: $e');
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  // --- Per-file actions (driven by the row overflow menu) ---

  Future<void> _handleAction(FileSnapshot file, String action) async {
    final ref = file.reference;
    switch (action) {
      case 'pin':
        try {
          await ref.keepCached();
          _reload();
          _snack('Cached: ${ref.path}');
        } catch (e) {
          _snack('Caching failed: $e');
        }
      case 'stale':
        try {
          final status = await ref.checkForUpdate();
          _snack('Cached copy: ${status.name}');
        } catch (e) {
          _snack('Status check failed: $e');
        }
      case 'refresh':
        try {
          await ref.refreshCache();
          _reload();
          _snack('Refreshed cache: ${ref.path}');
        } catch (e) {
          _snack('Refresh failed: $e');
        }
      case 'download':
        await _download(ref);
      case 'evict':
        try {
          await ref.clearCache();
          _reload();
          _snack('Cleared cached copy: ${ref.path}');
        } catch (e) {
          _snack('Clearing the cache failed: $e');
        }
      case 'delete':
        try {
          await ref.delete();
          _reload();
          _loadPending(); // delete() drops any queued transfer for the path
          _snack('Deleted: ${ref.path}');
        } catch (e) {
          _snack('Delete failed: $e');
        }
    }
  }

  Future<void> _download(ChildReference ref) async {
    final dir = await getApplicationDocumentsDirectory();
    final saveTo = p.join(dir.path, 'winche_downloads', ref.name);
    // One-shot with in-session retry. Downloads are not persisted: the bytes
    // stay authoritative on the server, so an interrupted download costs
    // bandwidth to redo, never data. `downloadFor(path)` finds it again if this
    // handle is lost while it runs.
    setState(() => currentDownloadTask = ref.download(saveTo));
    try {
      await currentDownloadTask!.whenDone;
      _snack('Download complete: ${ref.path}');
    } catch (e) {
      _snack('Download failed: $e');
    } finally {
      if (mounted) setState(() => currentDownloadTask = null);
    }
  }

  // --- AppBar actions ---

  Future<void> _clearOfflineCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear the file cache?'),
        content: const Text(
          'Removes every pinned local copy. Files stay on the server.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await storage.clearCache();
    _reload();
    _snack('Offline cache cleared');
  }

  Future<void> _upload() async {
    final result = await FilePicker.pickFiles(
      type: FileType.any,
      allowMultiple: false,
      withData: true,
    );
    final picked = result?.files.first;
    if (picked == null || (picked.path == null && picked.bytes == null)) {
      _snack('No file selected');
      return;
    }

    final file = root.child("test-${DateTime.now().millisecondsSinceEpoch}");
    setState(() {
      // Prefer a file-backed upload: it joins the durable queue and shows up in
      // pendingUploads(). Fall back to bytes when no path is available (web).
      currentUploadTask = picked.path != null
          ? file.uploadPath(
              picked.path!,
              metadata: {"description": "Test file upload"},
              enqueue: queueUploads,
              cache: cacheUploads,
            )
          : file.uploadBytes(
              picked.bytes!,
              "application/octet-stream",
              metadata: {"description": "Test file upload"},
              cache: cacheUploads,
            );
    });
    _loadPending(); // a transfer was just queued

    try {
      final record = await currentUploadTask!.whenDone;
      _snack(
        'Upload complete: ${record?.reference.path}'
        '${cacheUploads ? ' (available offline)' : ''}',
      );
    } catch (e) {
      _snack('Upload failed (queued for retry if auto-resume is on): $e');
    } finally {
      if (mounted) setState(() => currentUploadTask = null);
      _reload();
      _loadPending();
    }
  }

  /// The "Server" tab — a live `listChildren()` listing. Each file is annotated
  /// with whether this device holds its bytes. No offline fallback: listings
  /// are never cached, so being offline is an error rather than a partial view.
  Widget _buildServerList() {
    return _buildList(emptyMessage: 'No files found');
  }

  /// The "Cached" tab — the same listing, filtered to the files this device has
  /// bytes for. No second read: `isCached` rides along on every snapshot.
  Widget _buildCachedList() {
    return _buildList(
      emptyMessage: 'No files cached for offline use',
      where: (f) => f.isCached,
    );
  }

  Widget _buildList({
    required String emptyMessage,
    bool Function(FileSnapshot)? where,
  }) {
    return FutureBuilder<DirectorySnapshot>(
      future: _listing,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          // Listings are server-only, so this is also what being offline looks
          // like. There is no cached listing to fall back to by design — for
          // offline-capable structured data, use winche_database.
          return Center(child: Text('Error loading files: ${snapshot.error}'));
        }
        final files = where == null
            ? snapshot.data!.files
            : snapshot.data!.files.where(where).toList();
        if (files.isEmpty) return Center(child: Text(emptyMessage));
        return ListView.separated(
          itemCount: files.length,
          separatorBuilder: (context, index) => const Divider(height: 1),
          itemBuilder: (context, index) => _FileTile(
            file: files[index],
            cached: files[index].isCached,
            onAction: _handleAction,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Winche Storage — ${widget.uid}'),
        actions: [
          _UserMenu(uid: widget.uid, onSwitchUser: widget.onSwitchUser),
          // Per-call upload flags + actions, consolidated into one menu.
          PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'pin':
                  setState(() => cacheUploads = !cacheUploads);
                case 'queue':
                  setState(() => queueUploads = !queueUploads);
                case 'reload':
                  _reload();
                case 'clear':
                  _clearOfflineCache();
              }
            },
            itemBuilder: (context) => [
              CheckedPopupMenuItem(
                value: 'pin',
                checked: cacheUploads,
                child: const Text('Keep offline (cache)'),
              ),
              CheckedPopupMenuItem(
                value: 'queue',
                checked: queueUploads,
                child: const Text('Durable upload (enqueue)'),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'reload', child: Text('Reload list')),
              const PopupMenuItem(
                  value: 'clear', child: Text('Clear the file cache')),
            ],
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Server', icon: Icon(Icons.cloud_outlined)),
            Tab(text: 'Cached', icon: Icon(Icons.offline_pin)),
          ],
        ),
      ),
      body: Column(
        children: [
          if (currentUploadTask != null)
            _TransferProgressBanner(
              color: Colors.blue,
              label: 'Upload',
              stream: currentUploadTask!.stateStream,
              statusOf: (s) => s.status.name,
              progressOf: (s) => s.progress,
              isRunning: (s) => s.status == UploadTaskStatus.running,
              isPaused: (s) => s.status == UploadTaskStatus.paused,
              onPause: () => currentUploadTask!.pause(),
              onResume: () => currentUploadTask!.resume(),
              onCancel: () => currentUploadTask!.cancel(),
            ),
          if (currentDownloadTask != null)
            _TransferProgressBanner(
              color: Colors.green,
              label: 'Download',
              stream: currentDownloadTask!.stateStream,
              statusOf: (s) => s.status.name,
              progressOf: (s) => s.progress,
              isRunning: (s) => s.status == DownloadTaskStatus.running,
              isPaused: (s) => s.status == DownloadTaskStatus.paused,
              onPause: () => currentDownloadTask!.pause(),
              onResume: () => currentDownloadTask!.resume(),
              onCancel: () => currentDownloadTask!.cancel(),
            ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildServerList(),
                _buildCachedList(),
              ],
            ),
          ),
          _PendingTransfersPanel(
            records: _pending,
            expanded: _pendingExpanded,
            onToggle: () =>
                setState(() => _pendingExpanded = !_pendingExpanded),
            onRefresh: _loadPending,
            onReattach: _reattach,
          ),
          _TransferEventsFeed(
            events: _events,
            expanded: _eventsExpanded,
            onToggle: () => setState(() => _eventsExpanded = !_eventsExpanded),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _upload,
        child: const Icon(Icons.upload),
      ),
    );
  }
}

/// A reusable upload/download progress banner with pause/resume/cancel.
class _TransferProgressBanner<S> extends StatelessWidget {
  final Color color;
  final String label;
  final Stream<S> stream;
  final String Function(S) statusOf;
  final double Function(S) progressOf;
  final bool Function(S) isRunning;
  final bool Function(S) isPaused;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onCancel;

  const _TransferProgressBanner({
    required this.color,
    required this.label,
    required this.stream,
    required this.statusOf,
    required this.progressOf,
    required this.isRunning,
    required this.isPaused,
    required this.onPause,
    required this.onResume,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
      child: StreamBuilder<S>(
        stream: stream,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return Row(
              children: [
                Text('$label starting...'),
                const Spacer(),
                const CircularProgressIndicator(),
              ],
            );
          }
          final state = snapshot.data as S;
          return Row(
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('$label: ${statusOf(state)}'),
                  Text(
                    'Progress: ${(progressOf(state) * 100).toStringAsFixed(2)}%',
                  ),
                ],
              ),
              const Spacer(),
              if (isRunning(state))
                IconButton(onPressed: onPause, icon: const Icon(Icons.pause))
              else if (isPaused(state))
                IconButton(
                  onPressed: onResume,
                  icon: const Icon(Icons.play_arrow),
                ),
              IconButton(onPressed: onCancel, icon: const Icon(Icons.close)),
            ],
          );
        },
      ),
    );
  }
}

/// One file row: a cache-state leading icon and an overflow menu exposing the
/// full cache lifecycle (cache / check / refresh / download / clear / delete).
class _FileTile extends StatelessWidget {
  final FileSnapshot file;

  /// Whether this device holds the file's bytes. Comes straight off the
  /// snapshot — the listing annotates every file, so no second read is needed.
  final bool cached;
  final Future<void> Function(FileSnapshot file, String action) onAction;

  const _FileTile(
      {required this.file, required this.cached, required this.onAction});

  @override
  Widget build(BuildContext context) {
    final data = file.data!;
    return ListTile(
      leading: Icon(
        cached ? Icons.offline_pin : Icons.cloud_outlined,
        color: cached ? Colors.green : null,
      ),
      title: Text(file.reference.path),
      subtitle: Text(
        'Size: ${data.sizeBytes} bytes · ${data.mimeType} · ${data.contentHash}\n'
        'Cached: $cached'
        // localPath lives on the snapshot, not on FileData: it is this
        // device's state, and FileData carries only what the server sent.
        '${file.localPath != null ? ' (${file.localPath})' : ''}',
      ),
      isThreeLine: true,
      trailing: PopupMenuButton<String>(
        onSelected: (action) => onAction(file, action),
        itemBuilder: (context) => const [
          PopupMenuItem(value: 'pin', child: Text('Keep cached')),
          PopupMenuItem(value: 'stale', child: Text('Check for update')),
          PopupMenuItem(value: 'refresh', child: Text('Refresh cache')),
          PopupMenuItem(value: 'download', child: Text('Download to path')),
          PopupMenuItem(value: 'evict', child: Text('Clear cached copy')),
          PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
    );
  }
}

/// A collapsible feed of the most recent auto-resume transfer events.
class _TransferEventsFeed extends StatelessWidget {
  final List<TransferEvent> events;
  final bool expanded;
  final VoidCallback onToggle;

  const _TransferEventsFeed({
    required this.events,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 4,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            dense: true,
            leading: const Icon(Icons.sync),
            title: Text('Transfer events (${events.length})'),
            trailing: Icon(expanded ? Icons.expand_more : Icons.expand_less),
            onTap: onToggle,
          ),
          if (expanded)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 160),
              child: events.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('No transfer events yet'),
                    )
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        for (final e in events)
                          ListTile(
                            dense: true,
                            leading: Icon(_iconFor(e.type), size: 18),
                            title: Text('${e.type.name} · ${e.kind.name}'),
                            subtitle: Text(e.path),
                          ),
                      ],
                    ),
            ),
        ],
      ),
    );
  }

  IconData _iconFor(TransferEventType type) {
    switch (type) {
      case TransferEventType.started:
        return Icons.play_arrow;
      case TransferEventType.completed:
        return Icons.check_circle;
      case TransferEventType.failed:
        return Icons.error_outline;
      case TransferEventType.retrying:
        return Icons.refresh;
      case TransferEventType.paused:
        return Icons.pause_circle_outline;
    }
  }
}

/// A collapsible snapshot of the durable transfer queue, sourced from
/// `storage.pendingUploads()`. Each row is a not-yet-completed transfer
/// (pending / running / failed-awaiting-retry).
class _PendingTransfersPanel extends StatelessWidget {
  final List<TransferRecord> records;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onRefresh;
  final void Function(TransferRecord) onReattach;

  const _PendingTransfersPanel({
    required this.records,
    required this.expanded,
    required this.onToggle,
    required this.onRefresh,
    required this.onReattach,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 4,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            dense: true,
            leading: const Icon(Icons.cloud_upload_outlined),
            title: Text('Pending transfers (${records.length})'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Refresh',
                  onPressed: onRefresh,
                ),
                Icon(expanded ? Icons.expand_more : Icons.expand_less),
              ],
            ),
            onTap: onToggle,
          ),
          if (expanded)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 160),
              child: records.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('No pending uploads'),
                    )
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        for (final r in records)
                          ListTile(
                            dense: true,
                            // The queue is an outbox: every record is an upload.
                            leading: const Icon(Icons.upload, size: 18),
                            title: Text('${r.path} · ${r.status.name}'),
                            subtitle: Text(
                              'attempt ${r.attempt}'
                              '${r.lastError != null ? ' · ${r.lastError}' : ''}',
                            ),
                            trailing: const Icon(Icons.open_in_new, size: 16),
                            // Reattach this tracked transfer's live handle
                            // (uploadFor / downloadFor) to the progress banner.
                            onTap: () => onReattach(r),
                          ),
                      ],
                    ),
            ),
        ],
      ),
    );
  }
}

/// Switches identity, or signs out.
///
/// `PopupMenuButton` treats a *null* selection as a cancellation and calls
/// `onCanceled` instead of `onSelected`, so a "Sign out" item with `value:
/// null` would silently do nothing. `(uid: null)` is a non-null record that
/// still says "no user".
class _UserMenu extends StatelessWidget {
  final String uid;
  final Future<void> Function(String?) onSwitchUser;

  const _UserMenu({required this.uid, required this.onSwitchUser});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<({String? uid})>(
      tooltip: 'Signed in as $uid',
      icon: const Icon(Icons.person),
      onSelected: (choice) => onSwitchUser(choice.uid),
      itemBuilder: (context) => [
        for (final u in kUsers)
          PopupMenuItem<({String? uid})>(
            value: (uid: u),
            enabled: u != uid,
            child: Row(
              children: [
                Icon(u == uid ? Icons.check : Icons.person_outline, size: 18),
                const SizedBox(width: 8),
                Text(u),
              ],
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem<({String? uid})>(
          value: (uid: null),
          child: Row(
            children: [
              Icon(Icons.logout, size: 18),
              SizedBox(width: 8),
              Text('Sign out'),
            ],
          ),
        ),
      ],
    );
  }
}
