import 'upload_status.dart';

final class FileData {
  final String id;
  final String directory;
  final String path;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Map<String, dynamic> metadata;
  final int version;
  final String mimeType;
  final int sizeBytes;
  final UploadStatus uploadStatus;

  /// Absolute path to the locally stored copy of this file, or null when there
  /// is none. Set when the file is pinned/registered in the offline catalog.
  /// This is a client-side field — it is not part of the server record.
  final String? localPath;

  /// True when the file's content is actually downloaded locally and ready for
  /// offline use. Distinct from [localPath] (which is set as soon as a file is
  /// pinned, before its bytes finish downloading). Client-side field.
  final bool isCached;

  /// The server's content fingerprint (the object ETag) at the time this record
  /// was read. Changes when the file's bytes are overwritten, not on a
  /// metadata-only change. Null when the server hasn't recorded one. Server-side.
  final String? contentHash;

  const FileData({
    required this.id,
    required this.directory,
    required this.path,
    required this.createdAt,
    required this.updatedAt,
    required this.metadata,
    required this.version,
    required this.mimeType,
    required this.sizeBytes,
    required this.uploadStatus,
    this.localPath,
    this.isCached = false,
    this.contentHash,
  });

  factory FileData.fromJson(Map<String, dynamic> json) {
    return FileData(
      id: json['id'] as String,
      directory: json['directory'] as String,
      path: json['path'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      metadata: Map<String, dynamic>.from(json['metadata'] as Map),
      version: json['version'] as int,
      mimeType: json['mimeType'] as String,
      sizeBytes: json['sizeBytes'] as int,
      uploadStatus: UploadStatus.values.byName(json['uploadStatus'] as String),
      localPath: json['localPath'] as String?,
      isCached: json['isCached'] as bool? ?? false,
      contentHash: json['contentHash'] as String?,
    );
  }

  FileData copyWith({
    Map<String, dynamic>? metadata,
    UploadStatus? uploadStatus,
    DateTime? updatedAt,
    String? localPath,
    bool? isCached,
    String? contentHash,
  }) {
    return FileData(
      id: id,
      directory: directory,
      path: path,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      metadata: metadata ?? this.metadata,
      version: version,
      mimeType: mimeType,
      sizeBytes: sizeBytes,
      uploadStatus: uploadStatus ?? this.uploadStatus,
      localPath: localPath ?? this.localPath,
      isCached: isCached ?? this.isCached,
      contentHash: contentHash ?? this.contentHash,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'directory': directory,
        'path': path,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'metadata': metadata,
        'version': version,
        'mimeType': mimeType,
        'sizeBytes': sizeBytes,
        'uploadStatus': uploadStatus.name,
        'localPath': localPath,
        'isCached': isCached,
        'contentHash': contentHash,
      };
}
