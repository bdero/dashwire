import 'dart:async';
import 'dart:io';

import '../transport.dart';
import 'connect_io.dart';

/// Upgrades an HTTP request to a [WireConnection].
///
/// For servers that own their own [HttpServer] routing (static files plus a
/// WebSocket path); [WebSocketWireServer.bind] covers the simple case.
Future<WireConnection> upgradeWebSocket(HttpRequest request) async =>
    IoWebSocketConnection(await WebSocketTransformer.upgrade(request));

/// A WebSocket server producing [WireConnection]s. dart:io only.
final class WebSocketWireServer {
  WebSocketWireServer._(this._server) {
    _server.listen((request) async {
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        _connections.add(await upgradeWebSocket(request));
        return;
      }
      request.response
        ..statusCode = HttpStatus.notFound
        ..close();
    });
  }

  static Future<WebSocketWireServer> bind(Object address, int port) async =>
      WebSocketWireServer._(await HttpServer.bind(address, port));

  final HttpServer _server;
  final _connections = StreamController<WireConnection>();

  int get port => _server.port;

  /// Accepted connections. Hand each to a SessionListener.
  Stream<WireConnection> get connections => _connections.stream;

  Future<void> close() async {
    await _server.close();
    await _connections.close();
  }
}
