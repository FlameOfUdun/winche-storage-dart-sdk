final class UploadSession {
  final String url;
  final DateTime expiresAt;

  const UploadSession({required this.url, required this.expiresAt});

  factory UploadSession.fromJson(Map<String, dynamic> json) {
    return UploadSession(
      url: json['url'] as String,
      expiresAt: DateTime.parse(json['expiresAt'] as String),
    );
  }
}
