import 'package:sembast/sembast.dart';

/// Fallback for platforms with neither `dart:io` nor web libraries.
DatabaseFactory sembastFactory() =>
    throw UnsupportedError('No sembast database factory for this platform.');
