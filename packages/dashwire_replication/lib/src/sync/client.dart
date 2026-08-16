import 'package:dashwire/dashwire.dart';
import 'package:meta/meta.dart';

import 'dart:typed_data';

import '../net_id.dart';
import '../schema.dart';
import 'input.dart';
import 'messages.dart';

/// The receiving end of replication.
///
/// Instantiates replicas from spawn messages via the registry, applies
/// snapshots/updates, acks snapshot ticks, dispatches RPCs, and sends this
/// client's writes to owner-authority fields on [flush].
final class ReplicationClient implements ReplicaBinding {
  ReplicationClient({
    required this.registry,
    required this.session,
    this.inputTargetDepth = 2,
    this.onSpawn,
    this.onDespawn,
  }) {
    session.appMessages.listen(_handleMessage);
  }

  final ReplicaRegistry registry;
  final Session session;

  /// Server-side input buffer depth (ticks) the send-ahead lead converges
  /// to. Each buffered tick adds a tick of input latency; 2 rides out
  /// jitter on real links, 1 suits stable or local connections.
  final int inputTargetDepth;

  /// Called after a spawned replica's initial state is applied.
  final void Function(Replica replica)? onSpawn;

  /// Called before a replica is discarded.
  final void Function(Replica replica)? onDespawn;

  final Map<NetId, Replica> _replicas = {};
  final Map<NetId, int> _flushedVersion = {};
  int _writeSeq = 0;
  ClientInputSender? _input;

  Map<NetId, Replica> get replicas => Map.unmodifiable(_replicas);

  Replica? replicaById(NetId id) => _replicas[id];

  @override
  int get localPeerId => session.peerId;

  ClientInputSender get _inputSender =>
      _input ??= ClientInputSender(session, targetDepth: inputTargetDepth);

  /// The server tick a call to [sendInput] would target by default, one-way
  /// latency plus the adaptive send-ahead lead.
  int nextInputTick() => _inputSender.nextTick();

  /// Sends this client's input for a server tick.
  ///
  /// [payload] is game-defined (the input struct for that tick). Defaults to
  /// [nextInputTick]. The sender resends a short tail on the unreliable
  /// channel so a dropped packet self-heals, and adapts its lead from the
  /// server's ack. Consumed authoritatively by the room's tick via
  /// `ReplicationHost.consumeInput`.
  void sendInput(Uint8List payload, {int? tick}) =>
      _inputSender.send(tick ?? _inputSender.nextTick(), payload);

  /// Highest input tick the server has confirmed applying, 0 before any ack.
  /// The reconciliation baseline, replay resumes just after this tick.
  int get lastAppliedInputTick => _input?.lastAppliedTick ?? 0;

  /// Buffered input ticks the server holds ahead of what it has applied, as
  /// of the last ack. A healthy cushion sits near the sender's target depth.
  int get inputBufferDepth => _input?.bufferDepth ?? 0;

  /// Ticks the input sender currently sends ahead of the server, adapted from
  /// the server's buffer-depth feedback toward [inputTargetDepth].
  ///
  /// A caller passing an explicit tick to [sendInput] should pace it from
  /// this, otherwise the send-ahead never deepens under jitter and the
  /// server's input buffer starves.
  int get inputLeadTicks => _inputSender.leadTicks;

  void _handleMessage(NetMessage message) {
    final r = ByteReader(message.payload);
    switch (r.readU8()) {
      case MessageKind.spawn:
        final id = NetId.decode(r);
        final typeId = r.readU32();
        final owner = r.readVarUint();
        final mask = r.readU32();
        if (_replicas.containsKey(id)) return;
        final replica = registry.instantiate(typeId);
        if (replica == null) return;
        replica
          ..id = id
          ..owner = owner
          ..binding = this;
        replica.decodeFields(r, mask);
        _replicas[id] = replica;
        _flushedVersion[id] = replica.version;
        onSpawn?.call(replica);
      case MessageKind.despawn:
        final id = NetId.decode(r);
        final replica = _replicas.remove(id);
        _flushedVersion.remove(id);
        if (replica != null) {
          onDespawn?.call(replica);
          replica
            ..binding = null
            ..id = null;
        }
      case MessageKind.snapshot:
        final tick = r.readVarUint();
        final count = r.readVarUint();
        for (var i = 0; i < count; i++) {
          final id = NetId.decode(r);
          r.readVarUint(); // Version, meaningful to the server's ack state.
          final length = r.readVarUint();
          final replica = _replicas[id];
          if (replica == null) {
            r.readBytes(length);
            continue;
          }
          final entry = ByteReader(r.readBytes(length));
          replica.decodeFields(entry, entry.readU32());
          replica.markSnapshotTick(tick);
        }
        final ack = ByteWriter(8)
          ..writeU8(MessageKind.snapshotAck)
          ..writeVarUint(tick);
        session.sendApp(Channel.unreliable, ack.toBytes());
      case MessageKind.update:
        final id = NetId.decode(r);
        final replica = _replicas[id];
        if (replica == null) return;
        replica.decodeFields(r, r.readU32());
      case MessageKind.rpcCall:
        final id = NetId.decode(r);
        final replica = _replicas[id];
        if (replica == null) return;
        final index = r.readVarUint();
        if (index >= replica.rpcs.length) return;
        final endpoint = replica.rpcs[index];
        endpoint.invokeErased(Session.serverPeerId, endpoint.decodeArgs(r));
      case MessageKind.inputAck:
        _input?.handleAck(r);
      default:
      // Unknown kinds are ignored for forward compatibility.
    }
  }

  /// Sends pending writes to owner-authority fields of replicas this client
  /// owns. Call once per local tick.
  void flush() {
    for (final MapEntry(key: id, value: replica) in _replicas.entries) {
      if (replica.owner != localPeerId) continue;
      final since = _flushedVersion[id] ?? 0;
      if (replica.version <= since) continue;
      var streamMask = 0;
      var reliableMask = 0;
      for (final field in replica.fields) {
        if (field.write != Authority.owner || field.changedAt <= since) {
          continue;
        }
        if (field.mode == SendMode.onChange) {
          reliableMask |= 1 << field.index;
        } else if (field.mode == SendMode.stream) {
          streamMask |= 1 << field.index;
        }
      }
      _flushedVersion[id] = replica.version;
      if (streamMask != 0) {
        _sendOwnerWrite(id, replica, streamMask, Channel.unreliable);
      }
      if (reliableMask != 0) {
        _sendOwnerWrite(id, replica, reliableMask, Channel.reliable);
      }
    }
  }

  void _sendOwnerWrite(NetId id, Replica replica, int mask, Channel channel) {
    final w = ByteWriter(64)
      ..writeU8(MessageKind.ownerWrite)
      ..writeVarUint(_writeSeq++);
    id.encode(w);
    w.writeU32(mask);
    replica.encodeFields(w, mask);
    session.sendApp(channel, w.toBytes());
  }

  @override
  @internal
  void sendRpc(Replica replica, RpcEndpoint<Object?> endpoint, Object? args) {
    if (endpoint.to != RpcTarget.server) {
      throw StateError(
        'only server-target rpcs can be called from a client '
        '(${replica.typeKey}.${endpoint.name})',
      );
    }
    final w = ByteWriter(64)..writeU8(MessageKind.rpcCall);
    replica.id!.encode(w);
    w.writeVarUint(endpoint.index);
    endpoint.encodeArgsErased(w, args);
    session.sendApp(
      endpoint.delivery == Delivery.reliable
          ? Channel.reliable
          : Channel.unreliable,
      w.toBytes(),
    );
  }
}
