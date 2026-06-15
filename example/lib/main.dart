import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:winche_storage/winche_storage.dart';
import 'package:file_picker/file_picker.dart';

void main() async {
  final storage = WincheStorage(
    WincheStorageConfig(
      uri: Uri.parse('http://localhost:5209/files'),
      directoryResolver: () async {
        final dir = await getApplicationDocumentsDirectory();
        return "${dir.path}/winche_files";
      },
    ),
  );
  WidgetsFlutterBinding.ensureInitialized();

  runApp(_Application(storage: storage));
}

class _Application extends StatefulWidget {
  final WincheStorage storage;

  const _Application({required this.storage});

  @override
  State<_Application> createState() => _ApplicationState();
}

class _ApplicationState extends State<_Application> {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(home: _HomePage(storage: widget.storage));
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Winche Storage Example')),
      body: Column(
        children: [
          if (currentUploadTask != null)
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.blue,
                borderRadius: BorderRadius.circular(8),
              ),
              child: StreamBuilder(
                stream: currentUploadTask!.stateStream,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return Row(
                      children: [
                        const Text('Upload starting...'),
                        Spacer(),
                        const CircularProgressIndicator(),
                      ],
                    );
                  }

                  final state = snapshot.data;
                  final uploadStatus = state?.status;
                  final progress = state?.progress ?? 0.0;

                  return Row(
                    children: [
                      Column(
                        mainAxisAlignment: MainAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Upload Status: $uploadStatus'),
                          Text(
                            'Progress: ${(progress * 100).toStringAsFixed(2)}%',
                          ),
                        ],
                      ),
                      Spacer(),
                      if (uploadStatus == UploadTaskStatus.running)
                        IconButton(
                          onPressed: () {
                            currentUploadTask!.pause();
                          },
                          icon: const Icon(Icons.pause),
                        )
                      else if (uploadStatus == UploadTaskStatus.paused)
                        IconButton(
                          onPressed: () {
                            currentUploadTask!.resume();
                          },
                          icon: const Icon(Icons.play_arrow),
                        ),
                      IconButton(
                        onPressed: () {
                          currentUploadTask!.cancel();
                        },
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  );
                },
              ),
            ),
          if (currentDownloadTask != null)
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.green,
                borderRadius: BorderRadius.circular(8),
              ),
              child: StreamBuilder(
                stream: currentDownloadTask!.stateStream,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return Row(
                      children: [
                        const Text('Download starting...'),
                        Spacer(),
                        const CircularProgressIndicator(),
                      ],
                    );
                  }

                  final state = snapshot.data;
                  final downloadStatus = state?.status;
                  final progress = state?.progress ?? 0.0;

                  return Row(
                    children: [
                      Column(
                        mainAxisAlignment: MainAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Download Status: $downloadStatus'),
                          Text(
                            'Progress: ${(progress * 100).toStringAsFixed(2)}%',
                          ),
                        ],
                      ),
                      Spacer(),
                      if (downloadStatus == DownloadTaskStatus.running)
                        IconButton(
                          onPressed: () {
                            currentDownloadTask!.pause();
                          },
                          icon: const Icon(Icons.pause),
                        )
                      else if (downloadStatus == DownloadTaskStatus.paused)
                        IconButton(
                          onPressed: () {
                            currentDownloadTask!.resume();
                          },
                          icon: const Icon(Icons.play_arrow),
                        ),
                      IconButton(
                        onPressed: () {
                          currentDownloadTask!.cancel();
                        },
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  );
                },
              ),
            ),
          Expanded(
            child: FutureBuilder(
              future: storage.child("userFiles/user-123").list(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(
                    child: Text('Error loading files: ${snapshot.error}'),
                  );
                }
                final files = snapshot.data ?? [];
                if (files.isEmpty) {
                  return const Center(child: Text('No files found'));
                }
                return ListView.separated(
                  itemCount: files.length,
                  separatorBuilder: (context, index) => const Divider(),
                  itemBuilder: (context, index) {
                    final file = files[index];
                    return ListTile(
                      title: Text(file.path),
                      subtitle: Text(
                        "Size: ${file.data!.sizeBytes} bytes, MimeType: ${file.data!.mimeType}, Metadata: ${file.data!.metadata}, ",
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            onPressed: () async {
                              setState(() {
                                currentDownloadTask = file.reference.download();
                              });
                              await currentDownloadTask!.whenDone;
                              setState(() {
                                currentDownloadTask = null;
                              });
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Download complete: ${file.path}',
                                  ),
                                ),
                              );
                            },
                            icon: const Icon(Icons.download),
                          ),
                          IconButton(
                            onPressed: () async {
                              await file.reference.delete();
                              setState(() {});
                            },
                            icon: const Icon(Icons.delete),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          final result = await FilePicker.pickFiles(
            type: FileType.any,
            allowMultiple: false,
            withData: true,
          );
          final path = result?.files.first.path;

          if (!context.mounted) return;

          if (path == null) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('No file selected')));
            return;
          }

          final file = root.child(
            "test-${DateTime.now().millisecondsSinceEpoch}",
          );
          setState(() {
            currentUploadTask = file.uploadBytes(
              result!.files.first.bytes!,
              "application/octet-stream",
              metadata: {"description": "Test file upload"},
            );
          });

          final record = await currentUploadTask!.whenDone;
          setState(() {
            currentUploadTask = null;
          });
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Upload complete: ${record?.path}')),
          );
        },
        child: const Icon(Icons.upload),
      ),
    );
  }
}
