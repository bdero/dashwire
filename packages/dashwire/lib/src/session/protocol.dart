/// Session frame layout. Every payload on a session connection starts with a
/// kind byte; the handshake runs on the reliable channel, pings on the
/// unreliable channel, and app frames pass through on whichever channel the
/// caller chose.
library;

/// Frame kind, the first byte of every session payload.
abstract final class FrameKind {
  /// Client hello, varint protocol version, u32 schema hash, token bytes.
  static const int hello = 1;

  /// Server accept, varint peer id, tick rate, server tick, server micros.
  static const int accept = 2;

  /// Server reject, u8 [RejectCode], reason string.
  static const int reject = 3;

  /// varint client-send micros.
  static const int ping = 4;

  /// varint client-send micros echo, server micros, server tick.
  static const int pong = 5;

  /// App payload, raw bytes follow.
  static const int app = 6;
}

abstract final class RejectCode {
  static const int versionMismatch = 1;
  static const int schemaMismatch = 2;
  static const int authFailed = 3;
}

/// Session protocol version, bumped on any frame-layout change.
const int protocolVersion = 1;
