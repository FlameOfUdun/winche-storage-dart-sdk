import 'package:winche_core/winche_core.dart';

import '../winche_storage.dart';

/// A `file:` link from the database's `expand` (`winche_database`'s
/// `snapshot.link('scan')`), as storage's own types.
extension FileLink on WincheLink {
  /// The file, as the server resolved it: its record (type, size, metadata,
  /// upload status). Null for other kinds, and when it wasn't resolved (hidden
  /// from this user, missing, or offline).
  FileSnapshot? get file {
    final record = json;
    if (kind != 'file' || record == null) return null;
    return FileSnapshot.fromData(FileData.fromJson(record), reference: fileRef);
  }

  /// The file's reference: download it, cache it, get a link, whether it was
  /// resolved or not.
  ChildReference get fileRef {
    if (kind != 'file') throw StateError('A $kind link is not a file; its target is "$target".');
    return WincheStorage.instanceFor(app).child(target);
  }
}
