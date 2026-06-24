import 'package:sembast/sembast_io.dart';

/// Native (VM/AOT) factory: persists to a file on disk.
DatabaseFactory sembastFactory() => databaseFactoryIo;
