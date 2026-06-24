// Selects the platform-appropriate sembast DatabaseFactory at compile time:
// `dart:io` on native, web libraries in the browser, otherwise an unsupported
// stub. Consumers call sembastFactory() without knowing the platform.
export 'sembast_factory_stub.dart'
    if (dart.library.io) 'sembast_factory_io.dart'
    if (dart.library.js_interop) 'sembast_factory_web.dart';
