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

/// [localFileName] joined under the `cache/` subdirectory of a scoped root.
/// Cached bytes are kept apart from `staging/` so [clearOfflineCache] can empty
/// the cache without disturbing an upload that is still in flight.
String cacheFilePath(
  String root,
  String id, {
  String? sourceName,
  String? mimeType,
}) =>
    localFilePath(p.join(root, 'cache'), id,
        sourceName: sourceName, mimeType: mimeType);

/// A deterministic FNV-1a (32-bit) hash of [s], rendered as 8 hex chars.
/// Dart's `String.hashCode` is not guaranteed stable across runs, so a resumed
/// upload could not recompute a `hashCode`-based path — this can.
String _stableHash(String s) {
  var hash = 0x811c9dc5; // FNV offset basis
  for (final unit in s.codeUnits) {
    hash ^= unit & 0xff;
    hash = (hash * 0x01000193) & 0xffffffff; // FNV prime, kept to 32 bits
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

/// The staging path for an in-progress pinned upload of [refPath]. Lives under a
/// `staging/` subdir of [directory], keyed by a stable hash of [refPath] (unique
/// per upload target) and intentionally extension-free. Deterministic, so a
/// resumed upload recomputes the same path.
String stagingFilePath(String directory, String refPath) =>
    p.normalize(p.join(directory, 'staging', _stableHash(refPath)));

/// `<root>/winche/<storageKey>/storage` — this identity's storage root.
///
/// The sembast index, the cached bytes and the staging area all live inside
/// it, so forgetting a user is a single directory removal and a signed-out
/// user's cache can never half-exist.
///
/// The layout is stack-wide: an identity gets one directory under `winche/`,
/// and each Winche package takes a subdirectory of its own beneath it. So
/// deleting `<root>/winche/<storageKey>` forgets that user across every Winche
/// package at once, rather than one delete per package.
///
/// [storageKey] comes from `WincheIdentity.storageKey` and needs no validation
/// here: it is a SHA-256 digest, so it is always 32 lowercase hex characters
/// whatever id the backend issued.
String scopedRootPath(String directory, String storageKey) =>
    p.normalize(p.join(directory, 'winche', storageKey, 'storage'));
