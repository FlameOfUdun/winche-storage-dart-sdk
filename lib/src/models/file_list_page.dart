import 'file_data.dart';

/// One page of a folder listing, as Firebase's `list()`: the files directly in
/// the folder ([items]), its sub-folders as full paths ([prefixes]), and the
/// token for the next page ([nextPageToken], null on the last).
final class FileListPage {
  final List<FileData> items;
  final List<String> prefixes;
  final String? nextPageToken;

  const FileListPage({required this.items, required this.prefixes, this.nextPageToken});

  factory FileListPage.fromJson(Map<String, dynamic> json) => FileListPage(
    items: [for (final e in json['items'] as List<dynamic>) FileData.fromJson(e as Map<String, dynamic>)],
    prefixes: [for (final e in json['prefixes'] as List<dynamic>) e as String],
    nextPageToken: json['nextPageToken'] as String?,
  );
}
