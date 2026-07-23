import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../transport.dart';
import 'framing.dart';

Future<WireConnection> connectWebSocketImpl(Uri uri) async =>
    IoWebSocketConnection(await WebSocket.connect(uri.toString()));

/// Adapts a dart:io [WebSocket] (client or server side) to [WireConnection].
final class IoWebSocketConnection implements WireConnection {
  IoWebSocketConnection(this._socket) {
    _socket.listen(
      (Object? data) {
        if (data is! List<int>) return;
        final message = unframe(
          data is Uint8List ? data : Uint8List.fromList(data),
        );
        if (message != null && !_messages.isClosed) _messages.add(message);
      },
      onDone: _onClosed,
      onError: (Object _) => _onClosed(),
      cancelOnError: true,
    );
  }

  final WebSocket _socket;
  final _messages = StreamController<NetMessage>();
  final _done = Completer<void>();

  @override
  bool get isOpen => _socket.readyState == WebSocket.open;

  @override
  Stream<NetMessage> get messages => _messages.stream;

  @override
  Future<void> get done => _done.future;

  @override
  void send(Channel channel, Uint8List payload) {
    if (!isOpen) throw StateError('send on a closed connection');
    _socket.add(frameForChannel(channel, payload));
  }

  void _onClosed() {
    if (!_messages.isClosed) _messages.close();
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> close() async {
    await _socket.close();
    _onClosed();
  }
}
