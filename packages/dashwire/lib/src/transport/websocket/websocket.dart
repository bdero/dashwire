import '../transport.dart';
import 'connect_stub.dart'
    if (dart.library.io) 'connect_io.dart'
    if (dart.library.js_interop) 'connect_web.dart'
    as impl;

/// Connects a [WireConnection] over WebSocket.
///
/// Works on every platform (dart:io natively, the browser WebSocket on web).
/// Both channels ride the single reliable-ordered WebSocket stream, so the
/// unreliable channel is delivered reliably here; code must not depend on
/// that (see [Channel]).
Future<WireConnection> connectWebSocket(Uri uri) =>
    impl.connectWebSocketImpl(uri);
