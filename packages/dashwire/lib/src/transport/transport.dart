import 'dart:typed_data';

/// Delivery class for a payload.
///
/// [reliable] payloads arrive exactly once, in order relative to other
/// reliable payloads on the same connection. [unreliable] payloads may be
/// dropped, duplicated, or reordered; transports whose wire is inherently
/// reliable (WebSocket) happen to deliver them reliably, and callers must
/// never depend on that.
enum Channel { reliable, unreliable }

/// A payload received from the remote end of a connection.
final class NetMessage {
  NetMessage(this.channel, this.payload);

  final Channel channel;
  final Uint8List payload;
}

/// A bidirectional message pipe between two endpoints.
///
/// Transport level only. Peer identity, handshakes, clocks, and ticks are
/// session concerns layered above; a raw connection just moves payloads.
abstract interface class WireConnection {
  bool get isOpen;

  /// Queues [payload] for delivery on [channel].
  ///
  /// The payload is captured at call time; the caller may reuse its buffer
  /// immediately. Throws [StateError] if the connection is closed.
  void send(Channel channel, Uint8List payload);

  /// Received payloads in arrival order. Done when the connection closes.
  Stream<NetMessage> get messages;

  /// Completes once the connection is fully closed, locally or remotely.
  Future<void> get done;

  Future<void> close();
}
