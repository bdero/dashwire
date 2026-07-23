import 'dart:async';
import 'dart:isolate';

/// Passed to a room entry inside its isolate.
final class RoomLaunch {
  RoomLaunch._(this.roomId, this.requestedPort, this._control);

  final String roomId;

  /// The port the room should bind, 0 to pick one.
  final int requestedPort;

  final SendPort _control;

  /// Report the actually bound port once listening; completes the pool's
  /// launch future.
  void reportPort(int port) => _control.send(port);
}

/// A running room isolate.
final class RoomHandle {
  RoomHandle._(this.roomId, this.port, this._isolate);

  final String roomId;

  /// The room's bound transport port.
  final int port;

  final Isolate _isolate;

  void kill() => _isolate.kill(priority: Isolate.immediate);
}

/// Runs one room per isolate, the scaling unit.
///
/// Each entry is a top-level or static function that builds its own
/// transport server, Room, and simulation, then calls
/// [RoomLaunch.reportPort]. A lobby maps room ids to ports.
final class IsolateRoomPool {
  final Map<String, RoomHandle> _rooms = {};

  Map<String, RoomHandle> get rooms => Map.unmodifiable(_rooms);

  Future<RoomHandle> launch(
    Future<void> Function(RoomLaunch launch) entry, {
    required String roomId,
    int port = 0,
  }) async {
    if (_rooms.containsKey(roomId)) {
      throw StateError('room already running ($roomId)');
    }
    final control = ReceivePort();
    final isolate = await Isolate.spawn(_roomMain, (
      entry,
      roomId,
      port,
      control.sendPort,
    ), debugName: 'room-$roomId');
    final boundPort = await control.first as int;
    control.close();
    final handle = RoomHandle._(roomId, boundPort, isolate);
    _rooms[roomId] = handle;
    return handle;
  }

  void kill(String roomId) => _rooms.remove(roomId)?.kill();

  void killAll() {
    for (final id in List.of(_rooms.keys)) {
      kill(id);
    }
  }

  static Future<void> _roomMain(
    (Future<void> Function(RoomLaunch), String, int, SendPort) args,
  ) async {
    final (entry, roomId, port, control) = args;
    await entry(RoomLaunch._(roomId, port, control));
  }
}
