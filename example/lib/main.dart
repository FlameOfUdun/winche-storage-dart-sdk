import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:winche_storage/winche_storage.dart';
import 'package:file_picker/file_picker.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final storage = WincheStorage(
    WincheStorageConfig(
      uri: Uri.parse('http://localhost:5209/files'),
      directoryResolver: () async {
        final dir = await getApplicationDocumentsDirectory();
        return p.join(dir.path, 'winche_files');
      },
      // directoryResolver's presence enables both the durable transfer queue
      // (auto-resume) and the offline cache — no extra flags needed.
    ),
  );

  runApp(_Application(storage: storage));
}

class _Application extends StatelessWidget {
  final WincheStorage storage;

  const _Application({required this.storage});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(home: _HomePage(storage: storage));
  }
}

class _HomePage extends StatefulWidget {
  final WincheStorage storage;

  const _HomePage({required this.storage});

  @override
  State<_HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<_HomePage>
    with SingleTickerProviderStateMixin {
  WincheStorage get storage => widget.storage;
  ChildReference get root => storage.child("userFiles/user-123");

  UploadTask? currentUploadTask;
  DownloadTask? currentDownloadTask;

  /// When on, uploads are kept available offline (`cache: true`) — staged and
  /// placed straight into the offline cache, no separate download roundtrip.
  bool cacheUploads = false;

  /// When on, file uploads are durable (`enqueue: true`) — queued, retried, and
  /// resumed after a restart, so they appear in the pending-transfers panel.
  bool queueUploads = true;

  /// The current directory listing (server-only) paired with the set of paths
  /// pinned for offline use (a separate cache-only read). Refreshed via [_reload].
  late Future<(DirectorySnapshot, Set<String>)> _listing;

  /// A cache-only listing via `offlineChildren()` — backs the "Cached" tab. Never
  /// contacts the server. Refreshed via [_reload].
  late Future<DirectorySnapshot> _cachedListing;

  /// Switches the file view between the server listing and the cached listing.
  late final TabController _tabController;

  /// Recent auto-resume transfer events (most recent first, capped).
  final List<TransferEvent> _events = [];
  bool _eventsExpanded = false;
  StreamSubscription<TransferEvent>? _eventsSub;

  /// Snapshot of the durable transfer queue (`storage.pendingTransfers()`).
  List<TransferRecord> _pending = const [];
  bool _pendingExpanded = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _listing = _loadListing();
    _cachedListing = root.offlineChildren();
    _loadPending();
    // Observe the durable transfer queue as it drains (auto-resume).
    _eventsSub = storage.transferEvents.listen((event) {
      if (!mounted) return;
      setState(() {
        _events.insert(0, event);
        if (_events.length > 10) _events.removeLast();
      });
      _loadPending(); // the queue changed — refresh the snapshot
    });
  }

  @override
  void dispose() {
    _eventsSub?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  void _reload() {
    setState(() {
      _listing = _loadListing();
      _cachedListing = root.offlineChildren();
    });
  }

  /// Loads the live server listing, plus the set of locally-pinned paths used to
  /// annotate rows. get/list are server-only now, so the offline state comes from
  /// a separate `offlineChildren()` (cache-only) read. When the server is
  /// unreachable, falls back to the cached partial view.
  Future<(DirectorySnapshot, Set<String>)> _loadListing() async {
    final cached = await _cachedPaths();
    try {
      return (await root.listChildren(), cached);
    } on StorageUnavailableException {
      return (await root.offlineChildren(), cached);
    }
  }

  /// The paths pinned for offline use directly under the root — a cache-only read
  /// via `offlineChildren()`. Empty when no store is configured.
  Future<Set<String>> _cachedPaths() async {
    try {
      final offline = await root.offlineChildren();
      return offline.files.map((f) => f.reference.path).toSet();
    } catch (_) {
      return const {};
    }
  }

  /// Loads the durable transfer-queue snapshot via `pendingTransfers()`.
  Future<void> _loadPending() async {
    try {
      final pending = await storage.pendingTransfers();
      if (mounted) setState(() => _pending = pending);
    } catch (_) {
      // No store configured — leave the snapshot empty.
    }
  }

  /// Reattaches a tracked transfer's live handle (uploadFor / downloadFor) to
  /// the progress banner — e.g. after a restart, when the original task object
  /// is gone but the durable transfer is still resuming.
  void _reattach(TransferRecord rec) {
    try {
      if (rec.kind == TransferKind.upload) {
        final t = storage.uploadFor(rec.path);
        if (t == null) {
          _snack('No live upload for ${rec.path}');
          return;
        }
        setState(() => currentUploadTask = t);
      } else {
        final t = storage.downloadFor(rec.path);
        if (t == null) {
          _snack('No live download for ${rec.path}');
          return;
        }
        setState(() => currentDownloadTask = t);
      }
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
          await ref.makeAvailableOffline();
          _reload();
          _snack('Pinned offline: ${ref.path}');
        } catch (e) {
          _snack('Pin failed: $e');
        }
      case 'stale':
        try {
          final status = await ref.offlineCopyStatus();
          _snack('Offline copy: ${status.name}');
        } catch (e) {
          _snack('Status check failed: $e');
        }
      case 'refresh':
        try {
          await ref.refreshOfflineCopy();
          _reload();
          _snack('Refreshed offline copy: ${ref.path}');
        } catch (e) {
          _snack('Refresh failed: $e');
        }
      case 'download':
        await _download(ref);
      case 'evict':
        try {
          await ref.removeOfflineCopy();
          _reload();
          _snack('Evicted local copy: ${ref.path}');
        } catch (e) {
          _snack('Evict failed: $e');
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
    // Durable: the download joins the queue and is reattachable via downloadFor.
    setState(() => currentDownloadTask = ref.download(saveTo, enqueue: true));
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
        title: const Text('Clear offline cache?'),
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
    await storage.clearOfflineCache();
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
      // pendingTransfers(). Fall back to bytes when no path is available (web).
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

  /// The "Server" tab — a live `listChildren()` listing, annotated with which
  /// paths are also cached, falling back to `offlineChildren()` when offline.
  Widget _buildServerList() {
    return FutureBuilder<(DirectorySnapshot, Set<String>)>(
      future: _listing,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(child: Text('Error loading files: ${snapshot.error}'));
        }
        final (dir, cached) = snapshot.data!;
        return Column(
          children: [
            if (dir.fromCache) _OfflineBanner(count: dir.length),
            Expanded(
              child: dir.isEmpty
                  ? Center(
                      child: Text(
                        dir.fromCache
                            ? 'No files pinned for offline use'
                            : 'No files found',
                      ),
                    )
                  : ListView.separated(
                      itemCount: dir.length,
                      separatorBuilder: (context, index) =>
                          const Divider(height: 1),
                      itemBuilder: (context, index) => _FileTile(
                        file: dir.files[index],
                        cached:
                            cached.contains(dir.files[index].reference.path),
                        onAction: _handleAction,
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }

  /// The "Cached" tab — a cache-only `offlineChildren()` listing. Never contacts
  /// the server; shows only the files pinned for offline use under the root.
  Widget _buildCachedList() {
    return FutureBuilder<DirectorySnapshot>(
      future: _cachedListing,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(child: Text('Error loading cache: ${snapshot.error}'));
        }
        final dir = snapshot.data!;
        if (dir.isEmpty) {
          return const Center(child: Text('No files pinned for offline use'));
        }
        return ListView.separated(
          itemCount: dir.length,
          separatorBuilder: (context, index) => const Divider(height: 1),
          itemBuilder: (context, index) => _FileTile(
            file: dir.files[index],
            cached: true,
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
        title: const Text('Winche Storage Example'),
        actions: [
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
                  value: 'clear', child: Text('Clear offline cache')),
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

/// Shown above the list when `list()` was served from the offline cache because
/// the server was unreachable — a partial, pinned-only view.
class _OfflineBanner extends StatelessWidget {
  final int count;

  const _OfflineBanner({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Colors.orange.shade100,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.cloud_off, size: 18, color: Colors.orange),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Offline — showing $count pinned file(s) only '
              '(stop the server to see this).',
            ),
          ),
        ],
      ),
    );
  }
}

/// One file row: an offline-state leading icon and an overflow menu exposing the
/// full offline lifecycle (pin / stale / refresh / download / evict / delete).
class _FileTile extends StatelessWidget {
  final FileSnapshot file;

  /// Whether this path is pinned for offline use — supplied by the parent from a
  /// separate `offlineChildren()` read, since the server-only listing no longer
  /// carries cache state.
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
        'Offline: $cached'
        '${data.localPath != null ? ' (${data.localPath})' : ''}',
      ),
      isThreeLine: true,
      trailing: PopupMenuButton<String>(
        onSelected: (action) => onAction(file, action),
        itemBuilder: (context) => const [
          PopupMenuItem(value: 'pin', child: Text('Make available offline')),
          PopupMenuItem(value: 'stale', child: Text('Check if stale')),
          PopupMenuItem(value: 'refresh', child: Text('Refresh offline copy')),
          PopupMenuItem(value: 'download', child: Text('Download to path')),
          PopupMenuItem(value: 'evict', child: Text('Evict local copy')),
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
    }
  }
}

/// A collapsible snapshot of the durable transfer queue, sourced from
/// `storage.pendingTransfers()`. Each row is a not-yet-completed transfer
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
                      child: Text('No pending transfers'),
                    )
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        for (final r in records)
                          ListTile(
                            dense: true,
                            leading: Icon(
                              r.kind == TransferKind.upload
                                  ? Icons.upload
                                  : Icons.download,
                              size: 18,
                            ),
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
