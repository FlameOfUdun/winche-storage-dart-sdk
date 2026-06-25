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
      // Pin files for offline use, with remote-first reads + cache fallback.
      enableOfflineCache: true,
      // Durable transfer queue: uploads/downloads resume after an app restart
      // and self-retry with backoff. Pending transfers resume on construction.
      enableAutoResume: true,
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

class _HomePageState extends State<_HomePage> {
  WincheStorage get storage => widget.storage;
  ChildReference get root => storage.child("userFiles/user-123");

  UploadTask? currentUploadTask;
  DownloadTask? currentDownloadTask;

  /// When on, uploads are pinned into the offline cache straight away
  /// (`makeAvailableOffline: true`) — no separate download roundtrip.
  bool pinOnUpload = false;

  /// The current directory listing. Refreshed via [_reload].
  late Future<DirectorySnapshot> _listing;

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
    _listing = root.list();
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
    super.dispose();
  }

  void _reload() {
    setState(() {
      _listing = root.list();
    });
  }

  /// Loads the durable transfer-queue snapshot via `pendingTransfers()`.
  Future<void> _loadPending() async {
    try {
      final pending = await storage.pendingTransfers();
      if (mounted) setState(() => _pending = pending);
    } catch (_) {
      // auto-resume disabled — leave the snapshot empty
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
          // Returns false when offline (can't confirm) — never throws on that.
          final stale = await ref.isStale();
          _snack(stale ? 'Stale: ${ref.path}' : 'Up to date: ${ref.path}');
        } catch (e) {
          _snack('Stale check failed: $e');
        }
      case 'refresh':
        try {
          await ref.refresh();
          _reload();
          _snack('Refreshed offline copy: ${ref.path}');
        } catch (e) {
          _snack('Refresh failed: $e');
        }
      case 'download':
        await _download(ref);
      case 'evict':
        try {
          await ref.evict();
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
              makeAvailableOffline: pinOnUpload,
            )
          : file.uploadBytes(
              picked.bytes!,
              "application/octet-stream",
              metadata: {"description": "Test file upload"},
              makeAvailableOffline: pinOnUpload,
            );
    });
    _loadPending(); // a transfer was just queued

    try {
      final record = await currentUploadTask!.whenDone;
      _snack(
        'Upload complete: ${record?.reference.path}'
        '${pinOnUpload ? ' (available offline)' : ''}',
      );
    } catch (e) {
      _snack('Upload failed (queued for retry if auto-resume is on): $e');
    } finally {
      if (mounted) setState(() => currentUploadTask = null);
      _reload();
      _loadPending();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Winche Storage Example'),
        actions: [
          // Pin-on-upload toggle.
          Row(
            children: [
              const Text('Pin on upload'),
              Switch(
                value: pinOnUpload,
                onChanged: (v) => setState(() => pinOnUpload = v),
              ),
            ],
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'reload') _reload();
              if (value == 'clear') _clearOfflineCache();
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'reload', child: Text('Reload list')),
              PopupMenuItem(
                value: 'clear',
                child: Text('Clear offline cache'),
              ),
            ],
          ),
        ],
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
            child: FutureBuilder<DirectorySnapshot>(
              future: _listing,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(
                    child: Text('Error loading files: ${snapshot.error}'),
                  );
                }
                final dir = snapshot.data!;
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
                                onAction: _handleAction,
                              ),
                            ),
                    ),
                  ],
                );
              },
            ),
          ),
          _PendingTransfersPanel(
            records: _pending,
            expanded: _pendingExpanded,
            onToggle: () =>
                setState(() => _pendingExpanded = !_pendingExpanded),
            onRefresh: _loadPending,
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
  final Future<void> Function(FileSnapshot file, String action) onAction;

  const _FileTile({required this.file, required this.onAction});

  @override
  Widget build(BuildContext context) {
    final data = file.data!;
    return ListTile(
      leading: Icon(
        data.isCached ? Icons.offline_pin : Icons.cloud_outlined,
        color: data.isCached ? Colors.green : null,
      ),
      title: Text(file.reference.path),
      subtitle: Text(
        'Size: ${data.sizeBytes} bytes · ${data.mimeType}\n'
        'Offline: ${data.isCached}'
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

  const _PendingTransfersPanel({
    required this.records,
    required this.expanded,
    required this.onToggle,
    required this.onRefresh,
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
                          ),
                      ],
                    ),
            ),
        ],
      ),
    );
  }
}
