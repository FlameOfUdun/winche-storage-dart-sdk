import '../models/file_data.dart';

/// Lifecycle of a pinned offline file.
enum CatalogStatus { downloading, ready, stale }

/// A pinned file tracked by the offline catalog: the remote [data] captured at
/// pin/refresh time, plus where it lives locally.
class CatalogEntry {
  final FileData data;
  final String localPath;
  final DateTime pinnedAt;
  final CatalogStatus status;

  const CatalogEntry({
    required this.data,
    required this.localPath,
    required this.pinnedAt,
    required this.status,
  });

  String get path => data.path;
  String get id => data.id;

  /// True when the content has finished downloading and is ready for offline use.
  bool get isCached => status == CatalogStatus.ready;

  CatalogEntry copyWith({
    FileData? data,
    String? localPath,
    DateTime? pinnedAt,
    CatalogStatus? status,
  }) =>
      CatalogEntry(
        data: data ?? this.data,
        localPath: localPath ?? this.localPath,
        pinnedAt: pinnedAt ?? this.pinnedAt,
        status: status ?? this.status,
      );

  Map<String, Object?> toJson() => {
        'data': data.toJson(),
        'localPath': localPath,
        'pinnedAt': pinnedAt.toIso8601String(),
        'status': status.name,
      };

  factory CatalogEntry.fromJson(Map<String, Object?> json) => CatalogEntry(
        data: FileData.fromJson(
            Map<String, dynamic>.from(json['data'] as Map)),
        localPath: json['localPath'] as String,
        pinnedAt: DateTime.parse(json['pinnedAt'] as String),
        status: CatalogStatus.values.byName(json['status'] as String),
      );
}
