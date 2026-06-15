final class DownloadSession {
  final String url;
  final DateTime expiresAt;

  const DownloadSession({required this.url, required this.expiresAt});

  factory DownloadSession.fromJson(Map<String, dynamic> json) {
    return DownloadSession(
      url: json['url'] as String,
      expiresAt: DateTime.parse(json['expiresAt'] as String),
    );
  }
}
