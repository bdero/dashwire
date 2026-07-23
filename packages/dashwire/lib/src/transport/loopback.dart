import 'dart:async';
import 'dart:typed_data';

import 'transport.dart';

/// In-process connection pair for tests, listen servers, and demos.
///
/// Delivery is asynchronous (stream microtask order) but lossless and
/// ordered on both channels.
final class LoopbackConnection implements WireConnection {
  LoopbackConnection._();

  /// Creates two connected ends.
  static (LoopbackConnection, LoopbackConnection) pair() {
    final a = LoopbackConnection._();
    final b = LoopbackConnection._();
    a._remote = b;
    b._remote = a;
    return (a, b);
  }

  late final LoopbackConnection _remote;
  final _messages = StreamController<NetMessage>();
  final _done = Completer<void>();
  bool _open = true;

  @override
  bool get isOpen => _open;

  @override
  Stream<NetMessage> get messages => _messages.stream;

  @override
  Future<void> get done => _done.future;

  @override
  void send(Channel channel, Uint8List payload) {
    if (!_open) throw StateError('send on a closed connection');
    // Copy so the caller reusing its buffer cannot corrupt the message.
    _remote._deliver(NetMessage(channel, Uint8List.fromList(payload)));
  }

  void _deliver(NetMessage message) {
    if (!_open) return;
    _messages.add(message);
  }

  @override
  Future<void> close() async {
    _closeEnd();
    _remote._closeEnd();
  }

  void _closeEnd() {
    if (!_open) return;
    _open = false;
    _messages.close();
    _done.complete();
  }
}
