import 'dart:typed_data';

import 'package:dashwire/dashwire.dart';
import 'package:meta/meta.dart';

import '../net_id.dart';
import '../schema.dart';
import 'input.dart';
import 'messages.dart';
import 'relevancy.dart';

/// Server-side replication tuning.
final class HostConfig {
  const HostConfig({
    this.snapshotBytesPerTick = 2048,
    this.maxPendingSnapshots = 128,
  });

  /// Per-connection budget for stream-field snapshots each tick.
  final int snapshotBytesPerTick;

  /// Unacked in-flight snapshot records kept per connection.
  final int maxPendingSnapshots;
}

class _HostReplica {
  _HostReplica(this.replica, this.importance, this.alwaysRelevant);

  final Replica replica;
  final double importance;
  bool alwaysRelevant;
}

class _Peer {
  // Carry is disabled so the per-tick snapshot size is a hard ceiling; idle
  // ticks must not bank burst allowance.
  _Peer(this.session, HostConfig config)
    : budget = ByteBudget(
        bytesPerTick: config.snapshotBytesPerTick,
        maxCarryTicks: 1,
      );

  final Session session;
  final ByteBudget budget;

  /// Ids spawned on this client.
  final Set<NetId> known = {};

  /// Highest replica version fully delivered via acked snapshots (or the
  /// reliable spawn payload).
  final Map<NetId, int> ackedVersion = {};

  /// Version through which onChange fields were reliably flushed.
  final Map<NetId, int> reliableVersion = {};

  /// In-flight snapshots awaiting ack, tick to (id, packedVersion).
  final Map<int, List<(NetId, int)>> pendingSnapshots = {};
  final List<int> pendingOrder = [];

  /// Latest applied owner-write sequence per replica.
  final Map<NetId, int> ownerWriteSeq = {};

  /// Priority accrued per replica since it last packed into a snapshot for
  /// this connection, importance times any per-connection scale. Resets on
  /// send, so a starved replica climbs monotonically until it fits.
  final Map<NetId, double> accumulated = {};

  /// This connection's tick-indexed input command buffer.
  final ServerInputBuffer input = ServerInputBuffer();
}

/// The authoritative end of replication.
///
/// Owns spawned replicas, computes per-peer relevancy, and flushes state on
/// [tick], spawns/despawns and onChange fields reliably, stream fields as
/// priority-packed unreliable snapshots delta-coded against acks.
final class ReplicationHost implements ReplicaBinding {
  ReplicationHost({
    required this.registry,
    this.config = const HostConfig(),
    NetIdAllocator? ids,
  }) : _ids = ids ?? NetIdAllocator.random();

  final ReplicaRegistry registry;
  final HostConfig config;
  final NetIdAllocator _ids;

  final Map<NetId, _HostReplica> _replicas = {};
  final Map<int, _Peer> _peers = {};

  /// Ids relevant to every peer regardless of filters.
  final Set<NetId> alwaysRelevant = {};

  /// Per-peer forced-relevant ids (your own pawn, private objects).
  final Map<int, Set<NetId>> relevantForPeer = {};

  /// App-supplied relevancy filters (spatial grids, teams, custom).
  final List<RelevancyFilter> filters = [];

  /// Child ids replicated iff their parent is relevant.
  final Map<NetId, Set<NetId>> dependents = {};

  /// Optional per-connection priority multiplier applied when packing
  /// snapshots, the general form of a distance falloff (nearer entities pack
  /// first). Returns a factor on a replica's accumulated priority for a peer;
  /// 1 leaves ordering unchanged. Starvation accrual is unaffected, so a
  /// scaled-down entity still eventually sends.
  double Function(int peerId, Replica replica)? priorityScale;

  int _lastSnapshotBytes = 0;

  @override
  int get localPeerId => Session.serverPeerId;

  Iterable<Replica> get replicas => _replicas.values.map((r) => r.replica);

  Replica? replicaById(NetId id) => _replicas[id]?.replica;

  /// Bytes of the largest snapshot sent during the last [tick].
  int get debugLastSnapshotBytes => _lastSnapshotBytes;

  /// The authoritative input a connection sent for [tick].
  ///
  /// Returns the game-defined payload the peer stamped for [tick], or the
  /// last one it applied when that tick is missing (hold-last, so a dropped
  /// packet never stalls the sim), or null before the peer sends any input.
  /// Call once per peer per fixed tick from the room's simulation callback.
  Uint8List? consumeInput(int peerId, int tick) =>
      _peers[peerId]?.input.consume(tick);

  /// Whether the last [consumeInput] for [peerId] had to hold the previous
  /// input because the exact tick had not arrived (input starvation).
  bool inputStarved(int peerId) => _peers[peerId]?.input.starvedLast ?? false;

  /// Starts replicating to [session] and stops when it closes.
  void attach(Session session) {
    final peer = _Peer(session, config);
    _peers[session.peerId] = peer;
    session.appMessages.listen(
      (message) => _handleMessage(peer, message),
      onDone: () => _peers.remove(session.peerId),
    );
    // Also drop the peer the moment the connection completes; done handlers
    // run in registration order, so a later-registered handler (a room's
    // leave callback despawning the player) never broadcasts to it.
    session.done.whenComplete(() => _peers.remove(session.peerId));
  }

  /// Spawns [replica] under a fresh id (or [id], for hydration) owned by
  /// [owner].
  ///
  /// With [alwaysRelevant] false the replica only reaches peers through
  /// [relevantForPeer], [filters], or [dependents].
  NetId spawn(
    Replica replica, {
    int owner = Session.serverPeerId,
    bool alwaysRelevant = true,
    double importance = 1,
    NetId? id,
  }) {
    id ??= _ids.next();
    replica
      ..id = id
      ..owner = owner
      ..binding = this;
    _replicas[id] = _HostReplica(replica, importance, alwaysRelevant);
    if (alwaysRelevant) this.alwaysRelevant.add(id);
    return id;
  }

  void despawn(NetId id) {
    final record = _replicas.remove(id);
    if (record == null) return;
    record.replica
      ..binding = null
      ..id = null;
    alwaysRelevant.remove(id);
    dependents.remove(id);
    for (final set in relevantForPeer.values) {
      set.remove(id);
    }
    for (final peer in _peers.values) {
      if (peer.known.remove(id)) _sendDespawn(peer, id);
      peer.ackedVersion.remove(id);
      peer.reliableVersion.remove(id);
      peer.ownerWriteSeq.remove(id);
      peer.accumulated.remove(id);
    }
  }

  Set<NetId> _relevantFor(int peerId) {
    final out = <NetId>{...alwaysRelevant, ...?relevantForPeer[peerId]};
    for (final filter in filters) {
      filter.collect(peerId, out.add);
    }
    // One dependent expansion pass per wave, until stable.
    var frontier = out.toList();
    while (frontier.isNotEmpty) {
      final next = <NetId>[];
      for (final id in frontier) {
        for (final dep in dependents[id] ?? const <NetId>{}) {
          if (out.add(dep)) next.add(dep);
        }
      }
      frontier = next;
    }
    out.removeWhere((id) => !_replicas.containsKey(id));
    return out;
  }

  /// Flushes replication for [tick]. Call once per fixed server tick.
  void tick(int tick) {
    _lastSnapshotBytes = 0;
    for (final peer in _peers.values) {
      final relevant = _relevantFor(peer.session.peerId);
      _flushSpawns(peer, relevant);
      _flushReliableUpdates(peer);
      _flushSnapshot(peer, tick);
      _flushInputAck(peer);
    }
  }

  void _flushInputAck(_Peer peer) {
    // Only peers that predict (send input) need the ack and the depth-driven
    // pacing feedback; silent for pure viewers.
    if (!peer.input.isActive) return;
    final w = ByteWriter(12);
    peer.input.writeAck(w);
    peer.session.sendApp(Channel.unreliable, w.toBytes());
  }

  void _flushSpawns(_Peer peer, Set<NetId> relevant) {
    for (final id in relevant) {
      if (peer.known.contains(id)) continue;
      _sendSpawn(peer, id, _replicas[id]!.replica);
    }
    final gone = peer.known.where((id) => !relevant.contains(id)).toList();
    for (final id in gone) {
      peer.known.remove(id);
      peer.ackedVersion.remove(id);
      peer.reliableVersion.remove(id);
      peer.accumulated.remove(id);
      _sendDespawn(peer, id);
    }
  }

  void _sendSpawn(_Peer peer, NetId id, Replica replica) {
    final peerId = peer.session.peerId;
    var mask = 0;
    for (final field in replica.fields) {
      if (field.readableBy(peerId)) mask |= 1 << field.index;
    }
    final w = ByteWriter(128)..writeU8(MessageKind.spawn);
    id.encode(w);
    w
      ..writeU32(registry.typeIdOf(replica))
      ..writeVarUint(replica.owner)
      ..writeU32(mask);
    replica.encodeFields(w, mask);
    peer.session.sendApp(Channel.reliable, w.toBytes());
    peer.known.add(id);
    // The reliable spawn payload carries current values of every readable
    // field, so both progress marks start at the current version.
    peer.ackedVersion[id] = replica.version;
    peer.reliableVersion[id] = replica.version;
  }

  void _sendDespawn(_Peer peer, NetId id) {
    if (!peer.session.isOpen) return;
    final w = ByteWriter(16)..writeU8(MessageKind.despawn);
    id.encode(w);
    peer.session.sendApp(Channel.reliable, w.toBytes());
  }

  void _flushReliableUpdates(_Peer peer) {
    final peerId = peer.session.peerId;
    for (final id in peer.known) {
      final replica = _replicas[id]!.replica;
      final since = peer.reliableVersion[id] ?? 0;
      if (replica.version <= since) continue;
      var mask = 0;
      for (final field in replica.fields) {
        if (field.mode == SendMode.onChange &&
            field.changedAt > since &&
            field.readableBy(peerId)) {
          mask |= 1 << field.index;
        }
      }
      peer.reliableVersion[id] = replica.version;
      if (mask == 0) continue;
      final w = ByteWriter(64)..writeU8(MessageKind.update);
      id.encode(w);
      w.writeU32(mask);
      replica.encodeFields(w, mask);
      peer.session.sendApp(Channel.reliable, w.toBytes());
    }
  }

  void _flushSnapshot(_Peer peer, int tick) {
    peer.budget.refill();
    final peerId = peer.session.peerId;

    // Candidates, known replicas with undelivered stream-field changes.
    final candidates = <(_HostReplica, int, double)>[];
    for (final id in peer.known) {
      final record = _replicas[id]!;
      final replica = record.replica;
      final acked = peer.ackedVersion[id] ?? 0;
      if (replica.version <= acked) continue;
      var mask = 0;
      for (final field in replica.fields) {
        if (field.mode == SendMode.stream &&
            field.changedAt > acked &&
            field.readableBy(peerId)) {
          mask |= 1 << field.index;
        }
      }
      if (mask == 0) continue;
      final scale = priorityScale?.call(peerId, replica) ?? 1.0;
      final acc = (peer.accumulated[id] ?? 0) + record.importance * scale;
      peer.accumulated[id] = acc;
      candidates.add((record, mask, acc));
    }
    if (candidates.isEmpty) return;
    candidates.sort((a, b) => b.$3.compareTo(a.$3));

    final w = ByteWriter(256)
      ..writeU8(MessageKind.snapshot)
      ..writeVarUint(tick);
    var count = 0;
    final entryWriter = ByteWriter(128);
    final sent = <(NetId, int)>[];
    final body = ByteWriter(512);

    for (final (record, mask, _) in candidates) {
      final replica = record.replica;
      final id = replica.id!;
      entryWriter.reset();
      entryWriter.writeU32(mask);
      replica.encodeFields(entryWriter, mask);
      final entryBytes = entryWriter.toBytes();

      final header = ByteWriter(24);
      id.encode(header);
      header
        ..writeVarUint(replica.version)
        ..writeVarUint(entryBytes.length);
      final cost = header.length + entryBytes.length;
      if (!peer.budget.trySpend(cost)) continue;
      body
        ..writeBytes(header.toBytes())
        ..writeBytes(entryBytes);
      sent.add((id, replica.version));
      peer.accumulated[id] = 0;
      count++;
    }
    if (count == 0) return;

    w.writeVarUint(count);
    w.writeBytes(body.toBytes());
    final bytes = w.toBytes();
    if (bytes.length > _lastSnapshotBytes) _lastSnapshotBytes = bytes.length;
    peer.session.sendApp(Channel.unreliable, bytes);

    peer.pendingSnapshots[tick] = sent;
    peer.pendingOrder.add(tick);
    while (peer.pendingOrder.length > config.maxPendingSnapshots) {
      peer.pendingSnapshots.remove(peer.pendingOrder.removeAt(0));
    }
  }

  void _handleMessage(_Peer peer, NetMessage message) {
    final r = ByteReader(message.payload);
    switch (r.readU8()) {
      case MessageKind.snapshotAck:
        final tick = r.readVarUint();
        final sent = peer.pendingSnapshots.remove(tick);
        if (sent == null) return;
        peer.pendingOrder.remove(tick);
        for (final (id, version) in sent) {
          final acked = peer.ackedVersion[id] ?? 0;
          if (version > acked) peer.ackedVersion[id] = version;
        }
      case MessageKind.ownerWrite:
        _handleOwnerWrite(peer, r);
      case MessageKind.rpcCall:
        _handleRpc(peer, r);
      case MessageKind.inputCommand:
        peer.input.ingest(r);
      default:
      // Clients send nothing else; ignore unknown kinds.
    }
  }

  void _handleOwnerWrite(_Peer peer, ByteReader r) {
    final seq = r.readVarUint();
    final id = NetId.decode(r);
    final mask = r.readU32();
    final record = _replicas[id];
    if (record == null) return;
    final replica = record.replica;
    if (replica.owner != peer.session.peerId) return;
    final last = peer.ownerWriteSeq[id] ?? -1;
    if (seq <= last) return;
    peer.ownerWriteSeq[id] = seq;
    // Only owner-authority fields may be written; a mask reaching further
    // rejects the whole message.
    var allowed = 0;
    for (final field in replica.fields) {
      if (field.write == Authority.owner) allowed |= 1 << field.index;
    }
    if (mask & ~allowed != 0) return;
    replica.decodeFields(r, mask, validateAgainst: peer.session.peerId);
  }

  void _handleRpc(_Peer peer, ByteReader r) {
    final id = NetId.decode(r);
    final replica = _replicas[id]?.replica;
    if (replica == null) return;
    final index = r.readVarUint();
    if (index >= replica.rpcs.length) return;
    final endpoint = replica.rpcs[index];
    if (endpoint.to != RpcTarget.server) return;
    if (endpoint.requireOwner && replica.owner != peer.session.peerId) return;
    final args = endpoint.decodeArgs(r);
    if (!endpoint.validateErased(peer.session.peerId, args)) return;
    endpoint.invokeErased(peer.session.peerId, args);
  }

  @override
  @internal
  void sendRpc(Replica replica, RpcEndpoint<Object?> endpoint, Object? args) {
    final id = replica.id!;
    switch (endpoint.to) {
      case RpcTarget.server:
        // Calling a server-target endpoint on the server runs it locally.
        endpoint.invokeErased(localPeerId, args);
      case RpcTarget.owner:
        final peer = _peers[replica.owner];
        if (peer != null) _sendRpcTo(peer, id, endpoint, args);
      case RpcTarget.others:
      case RpcTarget.all:
        for (final peer in _peers.values) {
          if (peer.known.contains(id)) _sendRpcTo(peer, id, endpoint, args);
        }
        if (endpoint.to == RpcTarget.all) {
          endpoint.invokeErased(localPeerId, args);
        }
    }
  }

  void _sendRpcTo(
    _Peer peer,
    NetId id,
    RpcEndpoint<Object?> endpoint,
    Object? args,
  ) {
    final w = ByteWriter(64)..writeU8(MessageKind.rpcCall);
    id.encode(w);
    w.writeVarUint(endpoint.index);
    endpoint.encodeArgsErased(w, args);
    peer.session.sendApp(
      endpoint.delivery == Delivery.reliable
          ? Channel.reliable
          : Channel.unreliable,
      w.toBytes(),
    );
  }
}
