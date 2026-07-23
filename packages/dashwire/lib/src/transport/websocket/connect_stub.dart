import '../transport.dart';

Future<WireConnection> connectWebSocketImpl(Uri uri) =>
    throw UnsupportedError('WebSocket is unavailable on this platform');
