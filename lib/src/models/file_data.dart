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
    );
  }

  FileData copyWith({
    Map<String, dynamic>? metadata,
    UploadStatus? uploadStatus,
    DateTime? updatedAt,
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
    );
  }
}
