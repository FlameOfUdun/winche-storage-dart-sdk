import 'package:path/path.dart' as p;

/// Minimal MIME → extension fallbacks for common types stored offline.
const _mimeExtensions = <String, String>{
  'image/png': '.png',
  'image/jpeg': '.jpg',
  'image/gif': '.gif',
  'image/webp': '.webp',
  'image/heic': '.heic',
  'application/pdf': '.pdf',
  'text/plain': '.txt',
  'application/json': '.json',
  'video/mp4': '.mp4',
  'audio/mpeg': '.mp3',
};

String _extensionFrom(String? sourceName, String? mimeType) {
  if (sourceName != null) {
    final slash = sourceName.lastIndexOf('/');
    final base = slash < 0 ? sourceName : sourceName.substring(slash + 1);
    final dot = base.lastIndexOf('.');
    if (dot > 0 && dot < base.length - 1) return base.substring(dot);
  }
  if (mimeType != null) {
    final ext = _mimeExtensions[mimeType.toLowerCase()];
    if (ext != null) return ext;
  }
  return '';
}

/// The local file name for a cached file: the immutable [id], plus an extension
/// derived from [sourceName] (falling back to [mimeType]) when [id] doesn't
/// already end with it.
String localFileName(String id, {String? sourceName, String? mimeType}) {
  final ext = _extensionFrom(sourceName, mimeType);
  if (ext.isEmpty) return id;
  if (id.toLowerCase().endsWith(ext.toLowerCase())) return id;
  return '$id$ext';
}

/// [localFileName] joined under [directory], normalized to the platform path
/// separator. `p.normalize` cleans up any mixed separators already present in
/// [directory] (e.g. a Windows path built with a stray `/`), so the result is
/// always consistent.
String localFilePath(
  String directory,
  String id, {
  String? sourceName,
  String? mimeType,
}) =>
    p.normalize(
      p.join(directory, localFileName(id, sourceName: sourceName, mimeType: mimeType)),
    );
