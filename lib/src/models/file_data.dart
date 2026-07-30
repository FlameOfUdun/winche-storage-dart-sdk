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

  /// The server's content fingerprint (the object ETag) at the time this record
  /// was read. Changes when the file's bytes are overwritten, not on a
  /// metadata-only change. Null when the server hasn't recorded one.
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
      contentHash: json['contentHash'] as String?,
    );
  }

  FileData copyWith({
    Map<String, dynamic>? metadata,
    UploadStatus? uploadStatus,
    DateTime? updatedAt,
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
        'contentHash': contentHash,
      };
}
