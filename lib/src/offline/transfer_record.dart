enum TransferStatus {
  pending,
  running,

  /// Halted on a condition that clears by itself — an expired token or no
  /// network. Distinct from [failed]: no attempt was counted, so a paused
  /// transfer never exhausts its retry budget just by waiting. [lastError]
  /// carries the reason.
  paused,

  failed,
}

/// A persisted in-flight **upload**. Stores *intent*; byte progress is
/// re-derived on resume by the task engine (multipart `listParts`).
///
/// Uploads only: a download is a cache fill whose bytes stay authoritative on
/// the server, so it is never persisted. See [TransferController].
class TransferRecord {
  final int seq;
  final String path;

  /// The local source file being uploaded.
  final String? localPath;
  final String? mimeType;
  final Map<String, dynamic>? metadata;
  final int? multipartThreshold;
  final TransferStatus status;
  final int attempt;
  final String? lastError;
  final DateTime createdAt;
  final bool pinned;

  const TransferRecord({
    required this.seq,
    required this.path,
    required this.localPath,
    required this.mimeType,
    required this.metadata,
    required this.multipartThreshold,
    required this.status,
    required this.attempt,
    required this.lastError,
    required this.createdAt,
    this.pinned = false,
  });

  TransferRecord copyWith({
    String? localPath,
    TransferStatus? status,
    int? attempt,
    String? lastError,
    bool? pinned,
  }) =>
      TransferRecord(
        seq: seq,
        path: path,
        localPath: localPath ?? this.localPath,
        mimeType: mimeType,
        metadata: metadata,
        multipartThreshold: multipartThreshold,
        status: status ?? this.status,
        attempt: attempt ?? this.attempt,
        lastError: lastError,
        createdAt: createdAt,
        pinned: pinned ?? this.pinned,
      );

  Map<String, Object?> toJson() => {
        'seq': seq,
        'path': path,
        'localPath': localPath,
        'mimeType': mimeType,
        'metadata': metadata,
        'multipartThreshold': multipartThreshold,
        'status': status.name,
        'attempt': attempt,
        'lastError': lastError,
        'createdAt': createdAt.toIso8601String(),
        'pinned': pinned,
      };

  factory TransferRecord.fromJson(Map<String, Object?> json) => TransferRecord(
        seq: json['seq'] as int,
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
        pinned: json['pinned'] as bool? ?? false,
      );
}
