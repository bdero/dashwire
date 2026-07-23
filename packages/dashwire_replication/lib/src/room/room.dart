import 'dart:async';
import 'dart:typed_data';

import 'package:dashwire/dashwire.dart';

import '../net_id.dart';
import '../schema.dart';
import '../sync/host.dart';

/// One fixed-tick simulation, its peers, and its replication state. The
/// unit of scaling, one room per isolate/process, state never spans rooms.
final class Room {
  Room({
    required this.registry,
    this.tickRate = 30,
    HostConfig config = const HostConfig(),
    FutureOr<bool> Function(Uint8List token)? verifyToken,
    this.onTick,
    this.onJoin,
    this.onLeave,
  }) : _ids = NetIdAllocator.random() {
    host = ReplicationHost(registry: registry, config: config, ids: _ids);
    _loop = TickLoop(tickRate: tickRate);
    _listener = SessionListener(
      schemaHash: registry.schemaHash,
      tickRate: tickRate,
      currentTick: () => _loop.tick,
      verifyToken: verifyToken,
    );
  }

  final ReplicaRegistry registry;
  final int tickRate;
  late final ReplicationHost host;
  final NetIdAllocator _ids;
  late final TickLoop _loop;
  late final SessionListener _listener;
  Timer? _pump;
  final Stopwatch _elapsed = Stopwatch();

  /// Simulation callback, runs once per fixed tick before replication
  /// flushes.
  final void Function(int tick)? onTick;

  final void Function(Session session)? onJoin;
  final void Function(Session session)? onLeave;

  final List<StreamSubscription<WireConnection>> _acceptorSubs = [];
  final Set<Session> _sessions = {};

  int get currentTick => _loop.tick;

  Iterable<Session> get sessions => _sessions;

  /// Handshakes [connection] into this room.
  Future<Session?> admit(WireConnection connection) async {
    final session = await _listener.accept(connection);
    if (session == null) return null;
    _sessions.add(session);
    host.attach(session);
    onJoin?.call(session);
    session.done.whenComplete(() {
      _sessions.remove(session);
      onLeave?.call(session);
    });
    return session;
  }

  /// Admits every connection produced by [acceptor] (a transport server's
  /// connections stream).
  void accept(Stream<WireConnection> acceptor) {
    _acceptorSubs.add(acceptor.listen(admit));
  }

  /// Starts the real-time tick pump. Use [advance] instead to drive time
  /// manually (tests, external loops).
  void start() {
    if (_pump != null) return;
    _elapsed.start();
    var last = _elapsed.elapsedMicroseconds;
    _pump = Timer.periodic(Duration(microseconds: 1000000 ~/ tickRate ~/ 2), (
      _,
    ) {
      final now = _elapsed.elapsedMicroseconds;
      advance((now - last) / 1e6);
      last = now;
    });
  }

  /// Feeds [elapsedSeconds] into the fixed-tick loop.
  void advance(double elapsedSeconds) {
    _loop.advance(elapsedSeconds, (tick) {
      onTick?.call(tick);
      host.tick(tick);
    });
  }

  Future<void> stop() async {
    _pump?.cancel();
    _pump = null;
    for (final sub in _acceptorSubs) {
      await sub.cancel();
    }
    for (final session in List.of(_sessions)) {
      await session.close();
    }
  }

  static const int _snapshotVersion = 1;

  /// Serializes the room's replicas and id-allocator state.
  ///
  /// Relevancy settings (filters, per-peer sets, dependents) are runtime
  /// wiring and are not captured; re-apply them after [hydrate].
  Uint8List snapshot() {
    final w = ByteWriter(1024)
      ..writeU8(_snapshotVersion)
      ..writeVarUint(_ids.session)
      ..writeVarUint(_ids.nextIndex);
    final replicas = host.replicas.toList();
    w.writeVarUint(replicas.length);
    for (final replica in replicas) {
      w.writeU32(registry.typeIdOf(replica));
      replica.id!.encode(w);
      w.writeVarUint(replica.owner);
      final body = ByteWriter(128);
      replica.encodeFields(body, 0xffffffff);
      w.writeLengthPrefixedBytes(body.toBytes());
    }
    return w.toBytes();
  }

  /// Restores replicas from a [snapshot]. Call on a fresh, empty room
  /// before [start]; hydrated replicas spawn always-relevant.
  void hydrate(Uint8List snapshot) {
    final r = ByteReader(snapshot);
    final version = r.readU8();
    if (version != _snapshotVersion) {
      throw FormatException('unknown room snapshot version $version');
    }
    _ids.restore(session: r.readVarUint(), nextIndex: r.readVarUint());
    final count = r.readVarUint();
    for (var i = 0; i < count; i++) {
      final typeId = r.readU32();
      final id = NetId.decode(r);
      final owner = r.readVarUint();
      final body = ByteReader(r.readLengthPrefixedBytes());
      final replica = registry.instantiate(typeId);
      if (replica == null) {
        throw FormatException('unknown replica type $typeId in snapshot');
      }
      replica.decodeFields(body, 0xffffffff);
      host.spawn(replica, owner: owner, id: id);
    }
  }
}

/// Where room snapshots persist between sessions. Implement over any store
/// (files, a database, object storage).
abstract interface class RoomStore {
  Future<void> save(String roomId, Uint8List snapshot);
  Future<Uint8List?> load(String roomId);
}

/// A [RoomStore] for tests and single-process setups.
final class MemoryRoomStore implements RoomStore {
  final Map<String, Uint8List> _blobs = {};

  @override
  Future<void> save(String roomId, Uint8List snapshot) async =>
      _blobs[roomId] = Uint8List.fromList(snapshot);

  @override
  Future<Uint8List?> load(String roomId) async => _blobs[roomId];
}
