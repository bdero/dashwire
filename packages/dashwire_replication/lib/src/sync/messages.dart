/// Replication submessage kinds riding session app payloads.
library;

abstract final class MessageKind {
  /// netId, u32 typeId, varint owner, u32 mask, field values. Reliable.
  static const int spawn = 1;

  /// netId. Reliable.
  static const int despawn = 2;

  /// varint tick, varint count, then per entry netId, varint version,
  /// varint byte length, u32 mask, values. Unreliable; unknown ids skip by
  /// length.
  static const int snapshot = 3;

  /// varint tick. Unreliable, client to server.
  static const int snapshotAck = 4;

  /// netId, u32 mask, values. Reliable, onChange-field flush.
  static const int update = 5;

  /// varint writeSeq, netId, u32 mask, values. Client to server writes of
  /// owner-authority fields.
  static const int ownerWrite = 6;

  /// netId, varint rpcIndex, args. Either direction.
  static const int rpcCall = 7;

  /// varint count, then per entry varint tick, length-prefixed payload
  /// (ticks ascending). Client to server, unreliable, redundant tail. The
  /// payload is game-defined; encode one-frame events as counters, not
  /// booleans, so a resent command reproduces them.
  static const int inputCommand = 8;

  /// varint lastAppliedTick, varint bufferDepth. Server to client,
  /// unreliable. Acks input progress and feeds the client's send-ahead lead.
  static const int inputAck = 9;
}
