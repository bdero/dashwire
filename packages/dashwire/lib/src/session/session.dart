import 'dart:async';
import 'dart:typed_data';

import '../time/net_clock.dart';
import '../transport/transport.dart';
import '../wire/byte_reader.dart';
import '../wire/byte_writer.dart';
import 'protocol.dart';

/// The server rejected a connection during handshake.
final class SessionRejected implements Exception {
  SessionRejected(this.code, this.reason);

  /// A [RejectCode] value.
  final int code;
  final String reason;

  @override
  String toString() => 'SessionRejected($code, $reason)';
}

/// An established session over a [WireConnection].
///
/// Adds peer identity, the server tick timeline, and ping-based clock sync
/// on top of a raw connection. App payloads ride [FrameKind.app] frames.
final class Session {
  Session._(
    this._conn, {
    required this.peerId,
    required this.tickRate,
    required NowMicros now,
    NetClock? clock,
    int Function()? currentTick,
    NowMicros? serverNow,
  }) : _now = now,
       _clock = clock,
       _currentTick = currentTick,
       _serverNow = serverNow {
    _conn.done.whenComplete(_onClosed);
  }

  final WireConnection _conn;

  /// This end's peer id on a client session, the remote client's peer id on
  /// a server-side session. The server is always peer [serverPeerId].
  final int peerId;

  final int tickRate;
  final NowMicros _now;
  final NetClock? _clock;
  final int Function()? _currentTick;
  final NowMicros? _serverNow;
  final _app = StreamController<NetMessage>();
  Timer? _pingTimer;

  static const int serverPeerId = 1;

  /// Clock sync against the server. Present on client sessions only.
  NetClock get clock =>
      _clock ?? (throw StateError('server sessions have no clock'));

  bool get isClient => _clock != null;
  bool get isOpen => _conn.isOpen;

  /// App payloads received from the remote end.
  Stream<NetMessage> get appMessages => _app.stream;

  Future<void> get done => _conn.done;

  /// Sends an app payload on [channel].
  void sendApp(Channel channel, Uint8List payload) {
    final w = ByteWriter(payload.length + 1)
      ..writeU8(FrameKind.app)
      ..writeBytes(payload);
    _conn.send(channel, w.toBytes());
  }

  void _startPings(Duration interval) {
    _sendPing();
    _pingTimer = Timer.periodic(interval, (_) => _sendPing());
  }

  void _sendPing() {
    if (!_conn.isOpen) return;
    final w = ByteWriter(12)
      ..writeU8(FrameKind.ping)
      ..writeVarUint(_now());
    _conn.send(Channel.unreliable, w.toBytes());
  }

  void _handleFrame(NetMessage message) {
    final r = ByteReader(message.payload);
    switch (r.readU8()) {
      case FrameKind.app:
        _app.add(NetMessage(message.channel, r.readBytes(r.remaining)));
      case FrameKind.ping:
        final clientSend = r.readVarUint();
        final w = ByteWriter(24)
          ..writeU8(FrameKind.pong)
          ..writeVarUint(clientSend)
          ..writeVarUint(_serverNow?.call() ?? _now())
          ..writeVarUint(_currentTick?.call() ?? 0);
        if (_conn.isOpen) _conn.send(Channel.unreliable, w.toBytes());
      case FrameKind.pong:
        final clientSend = r.readVarUint();
        final serverMicros = r.readVarUint();
        final serverTick = r.readVarUint();
        _clock?.addSample(
          clientSendMicros: clientSend,
          clientReceiveMicros: _now(),
          serverMicros: serverMicros,
          serverTick: serverTick,
        );
      default:
      // Unknown frames are ignored for forward compatibility.
    }
  }

  void _onClosed() {
    _pingTimer?.cancel();
    if (!_app.isClosed) _app.close();
  }

  Future<void> close() => _conn.close();
}

/// Opens a client session over [conn].
///
/// Sends the hello, waits for accept/reject, then starts periodic pings that
/// feed [Session.clock]. Throws [SessionRejected] or [TimeoutException].
Future<Session> connectSession(
  WireConnection conn, {
  required int schemaHash,
  Uint8List? authToken,
  Duration timeout = const Duration(seconds: 5),
  Duration pingInterval = const Duration(milliseconds: 250),
  NowMicros now = defaultNowMicros,
}) async {
  final hello = ByteWriter(32)
    ..writeU8(FrameKind.hello)
    ..writeVarUint(protocolVersion)
    ..writeU32(schemaHash)
    ..writeLengthPrefixedBytes(authToken ?? Uint8List(0));

  final accepted = Completer<Session>();
  final helloSentAt = now();
  Session? session;

  final sub = conn.messages.listen(
    (message) {
      if (accepted.isCompleted) {
        session?._handleFrame(message);
        return;
      }
      final r = ByteReader(message.payload);
      switch (r.readU8()) {
        case FrameKind.accept:
          final peerId = r.readVarUint();
          final tickRate = r.readVarUint();
          final serverTick = r.readVarUint();
          final serverMicros = r.readVarUint();
          final clock = NetClock(tickRate: tickRate)
            ..addSample(
              clientSendMicros: helloSentAt,
              clientReceiveMicros: now(),
              serverMicros: serverMicros,
              serverTick: serverTick,
            );
          session = Session._(
            conn,
            peerId: peerId,
            tickRate: tickRate,
            now: now,
            clock: clock,
          );
          accepted.complete(session);
        case FrameKind.reject:
          accepted.completeError(SessionRejected(r.readU8(), r.readString()));
        default:
        // Pre-accept frames of other kinds are ignored.
      }
    },
    onDone: () {
      if (!accepted.isCompleted) {
        accepted.completeError(
          StateError('connection closed during handshake'),
        );
      }
    },
  );

  conn.send(Channel.reliable, hello.toBytes());
  try {
    final result = await accepted.future.timeout(timeout);
    result._startPings(pingInterval);
    return result;
  } catch (_) {
    await sub.cancel();
    await conn.close();
    rethrow;
  }
}

/// Accepts client sessions on the server side of connections.
final class SessionListener {
  SessionListener({
    required this.schemaHash,
    required this.tickRate,
    required int Function() currentTick,
    FutureOr<bool> Function(Uint8List token)? verifyToken,
    NowMicros now = defaultNowMicros,
  }) : _currentTick = currentTick,
       _verifyToken = verifyToken,
       _now = now;

  final int schemaHash;
  final int tickRate;
  final int Function() _currentTick;
  final FutureOr<bool> Function(Uint8List token)? _verifyToken;
  final NowMicros _now;
  int _nextPeerId = Session.serverPeerId + 1;

  /// Performs the server side of the handshake on [conn].
  ///
  /// Returns the established session, or null when the client was rejected
  /// (mismatched version/schema, failed auth, timeout); the connection is
  /// closed in that case.
  Future<Session?> accept(
    WireConnection conn, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final result = Completer<Session?>();
    Session? session;

    Future<void> reject(int code, String reason) async {
      final w = ByteWriter(64)
        ..writeU8(FrameKind.reject)
        ..writeU8(code)
        ..writeString(reason);
      if (conn.isOpen) conn.send(Channel.reliable, w.toBytes());
      await conn.close();
      if (!result.isCompleted) result.complete(null);
    }

    final sub = conn.messages.listen(
      (message) async {
        if (result.isCompleted) {
          session?._handleFrame(message);
          return;
        }
        final r = ByteReader(message.payload);
        if (r.readU8() != FrameKind.hello) return;
        final version = r.readVarUint();
        if (version != protocolVersion) {
          await reject(
            RejectCode.versionMismatch,
            'protocol $version, expected $protocolVersion',
          );
          return;
        }
        final clientSchema = r.readU32();
        if (clientSchema != schemaHash) {
          await reject(RejectCode.schemaMismatch, 'schema hash mismatch');
          return;
        }
        final token = r.readLengthPrefixedBytes();
        if (_verifyToken != null && !await _verifyToken(token)) {
          await reject(RejectCode.authFailed, 'auth failed');
          return;
        }
        final peerId = _nextPeerId++;
        final w = ByteWriter(24)
          ..writeU8(FrameKind.accept)
          ..writeVarUint(peerId)
          ..writeVarUint(tickRate)
          ..writeVarUint(_currentTick())
          ..writeVarUint(_now());
        conn.send(Channel.reliable, w.toBytes());
        session = Session._(
          conn,
          peerId: peerId,
          tickRate: tickRate,
          now: _now,
          currentTick: _currentTick,
          serverNow: _now,
        );
        result.complete(session);
      },
      onDone: () {
        if (!result.isCompleted) result.complete(null);
      },
    );

    try {
      return await result.future.timeout(timeout);
    } on TimeoutException {
      await sub.cancel();
      await conn.close();
      return null;
    }
  }
}
