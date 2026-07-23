import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../transport.dart';
import 'framing.dart';

Future<WireConnection> connectWebSocketImpl(Uri uri) {
  final socket = web.WebSocket(uri.toString())..binaryType = 'arraybuffer';
  final connected = Completer<WireConnection>();
  final connection = _WebWebSocketConnection(socket);
  socket.onopen = ((web.Event _) {
    if (!connected.isCompleted) connected.complete(connection);
  }).toJS;
  socket.onerror = ((web.Event _) {
    if (!connected.isCompleted) {
      connected.completeError(StateError('WebSocket connect failed ($uri)'));
    }
  }).toJS;
  return connected.future;
}

final class _WebWebSocketConnection implements WireConnection {
  _WebWebSocketConnection(this._socket) {
    _socket.onmessage = ((web.MessageEvent event) {
      final data = event.data;
      if (!data.isA<JSArrayBuffer>()) return;
      final bytes = (data as JSArrayBuffer).toDart.asUint8List();
      final message = unframe(bytes);
      if (message != null && !_messages.isClosed) _messages.add(message);
    }).toJS;
    _socket.onclose = ((web.Event _) => _onClosed()).toJS;
  }

  final web.WebSocket _socket;
  final _messages = StreamController<NetMessage>();
  final _done = Completer<void>();

  @override
  bool get isOpen => _socket.readyState == web.WebSocket.OPEN;

  @override
  Stream<NetMessage> get messages => _messages.stream;

  @override
  Future<void> get done => _done.future;

  @override
  void send(Channel channel, Uint8List payload) {
    if (!isOpen) throw StateError('send on a closed connection');
    _socket.send(frameForChannel(channel, payload).buffer.toJS);
  }

  void _onClosed() {
    if (!_messages.isClosed) _messages.close();
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> close() async {
    _socket.close();
    _onClosed();
  }
}
