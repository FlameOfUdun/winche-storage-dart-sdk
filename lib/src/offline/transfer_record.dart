enum TransferKind { upload, download }

enum TransferStatus { pending, running, failed }

/// A persisted in-flight transfer. Stores *intent*; byte progress is re-derived
/// on resume by the existing task engine (multipart `listParts` for uploads,
/// on-disk length + HTTP `Range` for downloads).
class TransferRecord {
  final int seq;
  final TransferKind kind;
  final String path;

  /// Download: the resolved destination. Upload: the local source file.
  final String? localPath;
  final String? mimeType;
  final Map<String, dynamic>? metadata;
  final int? multipartThreshold;
  final TransferStatus status;
  final int attempt;
  final String? lastError;
  final DateTime createdAt;

  const TransferRecord({
    required this.seq,
    required this.kind,
    required this.path,
    required this.localPath,
    required this.mimeType,
    required this.metadata,
    required this.multipartThreshold,
    required this.status,
    required this.attempt,
    required this.lastError,
    required this.createdAt,
  });

  TransferRecord copyWith({
    String? localPath,
    TransferStatus? status,
    int? attempt,
    String? lastError,
  }) =>
      TransferRecord(
        seq: seq,
        kind: kind,
        path: path,
        localPath: localPath ?? this.localPath,
        mimeType: mimeType,
        metadata: metadata,
        multipartThreshold: multipartThreshold,
        status: status ?? this.status,
        attempt: attempt ?? this.attempt,
        lastError: lastError,
        createdAt: createdAt,
      );

  Map<String, Object?> toJson() => {
        'seq': seq,
        'kind': kind.name,
        'path': path,
        'localPath': localPath,
        'mimeType': mimeType,
        'metadata': metadata,
        'multipartThreshold': multipartThreshold,
        'status': status.name,
        'attempt': attempt,
        'lastError': lastError,
        'createdAt': createdAt.toIso8601String(),
      };

  factory TransferRecord.fromJson(Map<String, Object?> json) => TransferRecord(
        seq: json['seq'] as int,
        kind: TransferKind.values.byName(json['kind'] as String),
        path: json['path'] as String,
        localPath: json['localPath'] as String?,
        mimeType: json['mimeType'] as String?,
        metadata: json['metadata'] == null
            ? null
            : Map<String, dynamic>.from(json['metadata'] as Map),
        multipartThreshold: json['multipartThreshold'] as int?,
        status: TransferStatus.values.byName(json['status'] as String),
        attempt: json['attempt'] as int,
        lastError: json['lastError'] as String?,
        createdAt: DateTime.parse(json['createdAt'] as String),
      );
}
