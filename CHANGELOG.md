# CHANGELOG

## 1.1.0

* Uploading to an existing path now overwrites a completed file when the size or
  MIME type differs, and discards an interrupted attempt for different content
  instead of throwing — a previously failed upload no longer blocks the path.
* Files at or below `multipartThreshold` now upload in a single request via the
  backend's single-shot upload endpoint; only larger files use multipart. This
  also fixes empty (0-byte) uploads, which previously failed.
* Downloads now verify the written byte count against the remote record size and
  fail on a truncated transfer, deleting the partial file before reporting.

## 1.0.0

* Initial Release
