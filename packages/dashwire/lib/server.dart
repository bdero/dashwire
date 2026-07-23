/// Server-side pieces of dashwire that require dart:io.
///
/// Import alongside `package:dashwire/dashwire.dart` in server binaries;
/// never import from code that must compile for the web.
library;

export 'src/transport/websocket/websocket_server.dart'
    show WebSocketWireServer, upgradeWebSocket;
