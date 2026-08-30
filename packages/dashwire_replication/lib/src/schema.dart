import 'dart:typed_data';

import 'package:dashwire/dashwire.dart';
import 'package:meta/meta.dart';

import 'codec.dart';
import 'net_id.dart';

/// How a replicated field travels.
enum SendMode {
  /// Sent once in the spawn payload, never again.
  spawnOnly,

  /// Sent reliably when it changes; for state that changes rarely and must
  /// never be missed (names, scores, phases).
  onChange,

  /// Streamed unreliably while dirty, delta-coded against acks; for state
  /// that changes continuously (transforms, velocities).
  stream,
}

/// Who may write a field.
enum Authority { server, owner }

/// Who receives a field.
enum ReadScope { everyone, ownerOnly, skipOwner }

/// Where an RPC executes.
enum RpcTarget {
  /// On the server. The one direction a client may call: a client asking for
  /// something, with the server deciding.
  server,

  /// On the replica's owner, and locally when the server is the owner.
  owner,

  /// On every client that knows the replica, the server aside.
  others,

  /// On every client that knows the replica, and on the server.
  all,

  /// On every client that knows the replica except its owner, and on the
  /// server.
  ///
  /// The target for telling everyone about something its owner already knows:
  /// the client that fired has drawn its own muzzle flash, and sending it back
  /// is at best wasted and at worst a second flash a frame later. Distinct
  /// from [others], which is about the *server* not receiving rather than the
  /// owner.
  notOwner,
}

enum Delivery { reliable, unreliable }

/// Type-erased base of [Rep], what the sync pipeline iterates.
abstract base class RepField {
  RepField(
    this.replica,
    this.index,
    this.name,
    this.mode,
    this.write,
    this.read, {
    required this.codecId,
  });

  final Replica replica;
  final int index;
  final String name;
  final SendMode mode;
  final Authority write;
  final ReadScope read;
  final String codecId;

  /// Replica-version stamp of the last change. Internal to the pipeline.
  @internal
  int changedAt = 0;

  /// True when [peerId] may receive this field of [replica].
  @internal
  bool readableBy(int peerId) => switch (read) {
    ReadScope.everyone => true,
    ReadScope.ownerOnly => peerId == replica.owner,
    ReadScope.skipOwner => peerId != replica.owner,
  };

  @internal
  void encodeValue(ByteWriter w);

  /// Decodes and applies a value from the wire. When [validateAgainst] is a
  /// peer id, the field's validator gates the write and false means
  /// rejected (the decoded value is discarded).
  @internal
  bool decodeAndApply(ByteReader r, {int? validateAgainst});
}

/// A replicated field holding a [T].
///
/// Assign [value] normally; changes at wire precision mark the field dirty
/// and the pipeline takes it from there.
final class Rep<T> extends RepField {
  Rep._(
    super.replica,
    super.index,
    super.name,
    super.mode,
    super.write,
    super.read,
    this.codec,
    this._value,
    this._validate,
  ) : super(codecId: codec.id);

  final Codec<T> codec;
  T _value;
  final bool Function(int peerId, T value)? _validate;
  final List<void Function(T previous, T next)> _listeners = [];

  T get value => _value;

  set value(T next) {
    if (codec.equals(_value, next)) return;
    _apply(next);
  }

  void _apply(T next) {
    final previous = _value;
    _value = next;
    changedAt = replica.bumpVersion();
    for (final listener in _listeners) {
      listener(previous, next);
    }
  }

  /// Calls [listener] after every applied change, local or remote.
  void onChanged(void Function(T previous, T next) listener) =>
      _listeners.add(listener);

  @override
  @internal
  void encodeValue(ByteWriter w) => codec.encode(w, _value);

  @override
  @internal
  bool decodeAndApply(ByteReader r, {int? validateAgainst}) {
    final next = codec.decode(r);
    if (validateAgainst != null &&
        _validate != null &&
        !_validate(validateAgainst, next)) {
      return false;
    }
    if (!codec.equals(_value, next)) _apply(next);
    return true;
  }
}

/// A remote-procedure endpoint declared on a [Replica].
final class RpcEndpoint<T> {
  RpcEndpoint._(
    this.replica,
    this.index,
    this.name,
    this.codec,
    this.to,
    this.delivery,
    this._onCall,
    this._validate,
    this.requireOwner,
  );

  final Replica replica;
  final int index;
  final String name;
  final Codec<T> codec;
  final RpcTarget to;
  final Delivery delivery;
  final void Function(int fromPeerId, T args) _onCall;
  final bool Function(int fromPeerId, T args)? _validate;

  /// For [RpcTarget.server] endpoints, whether only the owner may call.
  final bool requireOwner;

  /// Invokes the endpoint. On a client this sends to the server (for
  /// [RpcTarget.server] endpoints); on the server it sends to the targeted
  /// peers, and [RpcTarget.all] also runs the handler locally.
  void call(T args) => replica.sendRpc(this, args);

  @internal
  void invoke(int fromPeerId, T args) => _onCall(fromPeerId, args);

  @internal
  bool validate(int fromPeerId, T args) =>
      _validate?.call(fromPeerId, args) ?? true;

  @internal
  void encodeArgs(ByteWriter w, T args) => codec.encode(w, args);

  @internal
  Object? decodeArgs(ByteReader r) => codec.decode(r);

  @internal
  void invokeErased(int fromPeerId, Object? args) =>
      _onCall(fromPeerId, args as T);

  @internal
  bool validateErased(int fromPeerId, Object? args) =>
      validate(fromPeerId, args as T);

  @internal
  void encodeArgsErased(ByteWriter w, Object? args) =>
      codec.encode(w, args as T);
}

/// Callback surface a [Replica] uses to reach whichever pipeline end
/// (host or client) it is bound to.
@internal
abstract interface class ReplicaBinding {
  void sendRpc(Replica replica, RpcEndpoint<Object?> endpoint, Object? args);
  int get localPeerId;
}

/// Base class for replicated objects.
///
/// Subclasses declare `late final` [Rep]/[RpcEndpoint] members and assign
/// them in the constructor BODY, registration order defines wire order on
/// both ends. Never use `late final x = rep(...)` initializers, those run
/// lazily on first read and would scramble the order (the schema hash
/// catches cross-build drift, not same-build access-order bugs). At most 32
/// fields per replica (the change mask is one u32).
///
/// ```dart
/// final class PlayerReplica extends Replica {
///   PlayerReplica() {
///     health = rep('health', 100, codec: Codecs.varUint);
///     position = rep('position', (0.0, 0.0, 0.0), codec: Codecs.vec3(0.01));
///   }
///
///   @override
///   String get typeKey => 'player';
///
///   late final Rep<int> health;
///   late final Rep<Vec3> position;
/// }
/// ```
abstract base class Replica {
  /// Stable type key; registry lookup and schema hashing use this, never
  /// runtimeType (minified on the web).
  String get typeKey;

  final List<RepField> _fields = [];
  final List<RpcEndpoint<Object?>> _rpcs = [];
  int _version = 0;

  @internal
  ReplicaBinding? binding;

  /// Identity while spawned, null before.
  NetId? id;

  /// Owning peer id (the server itself is peer 1).
  int owner = 1;

  int _snapshotTick = 0;

  /// Server tick of the newest snapshot that carried this replica's state, 0
  /// before any arrives.
  ///
  /// Snapshots are priority-packed against a per-peer byte budget and ride
  /// the unreliable channel, so this replica can sit several ticks behind
  /// both the newest snapshot and the per-tick input ack. A client
  /// reconciling prediction against this state must pin it to this tick, not
  /// to `ReplicationClient.lastAppliedInputTick`.
  int get snapshotTick => _snapshotTick;

  @internal
  void markSnapshotTick(int tick) {
    if (tick > _snapshotTick) _snapshotTick = tick;
  }

  @internal
  List<RepField> get fields => _fields;

  @internal
  List<RpcEndpoint<Object?>> get rpcs => _rpcs;

  /// Current change-version counter.
  @internal
  int get version => _version;

  @internal
  int bumpVersion() => ++_version;

  /// Declares a replicated field. Call only during construction.
  Rep<T> rep<T>(
    String name,
    T initial, {
    required Codec<T> codec,
    SendMode mode = SendMode.stream,
    Authority write = Authority.server,
    ReadScope read = ReadScope.everyone,
    bool Function(int peerId, T value)? validate,
  }) {
    if (_fields.length >= 32) {
      throw StateError('a replica supports at most 32 fields');
    }
    final field = Rep<T>._(
      this,
      _fields.length,
      name,
      mode,
      write,
      read,
      codec,
      initial,
      validate,
    );
    _fields.add(field);
    return field;
  }

  /// Declares an RPC endpoint. Call only during construction.
  RpcEndpoint<T> rpc<T>(
    String name, {
    required Codec<T> codec,
    required RpcTarget to,
    required void Function(int fromPeerId, T args) onCall,
    Delivery delivery = Delivery.reliable,
    bool Function(int fromPeerId, T args)? validate,
    bool requireOwner = true,
  }) {
    final endpoint = RpcEndpoint<T>._(
      this,
      _rpcs.length,
      name,
      codec,
      to,
      delivery,
      onCall,
      validate,
      requireOwner,
    );
    _rpcs.add(endpoint as RpcEndpoint<Object?>);
    return endpoint;
  }

  @internal
  void sendRpc(RpcEndpoint<Object?> endpoint, Object? args) {
    final bound = binding;
    if (bound == null) {
      throw StateError(
        'rpc on an unspawned replica ($typeKey.${endpoint.name})',
      );
    }
    bound.sendRpc(this, endpoint, args);
  }

  /// Encodes fields selected by [mask] in index order.
  @internal
  void encodeFields(ByteWriter w, int mask) {
    for (final field in _fields) {
      if (mask & (1 << field.index) != 0) field.encodeValue(w);
    }
  }

  /// Decodes fields selected by [mask]. With [validateAgainst], rejected
  /// writes stop applying but keep decoding so the stream stays aligned.
  @internal
  void decodeFields(ByteReader r, int mask, {int? validateAgainst}) {
    for (final field in _fields) {
      if (mask & (1 << field.index) != 0) {
        field.decodeAndApply(r, validateAgainst: validateAgainst);
      }
    }
  }
}

/// Factory table for spawnable replica types plus the schema hash.
final class ReplicaRegistry {
  final Map<int, Replica Function()> _factories = {};
  final Map<int, String> _typeKeys = {};
  final List<String> _schemaLines = [];

  /// Registers a replica type. The factory must produce a fully-declared
  /// instance (all fields/rpcs registered in its constructor).
  void register(Replica Function() create) {
    final prototype = create();
    final key = prototype.typeKey;
    final typeId = fnv1a32(key);
    if (_factories.containsKey(typeId)) {
      throw StateError('replica type already registered ($key)');
    }
    _factories[typeId] = create;
    _typeKeys[typeId] = key;
    final line = StringBuffer(key);
    for (final f in prototype.fields) {
      line.write(
        '|${f.name}:${f.codecId}:${f.mode.index}${f.write.index}${f.read.index}',
      );
    }
    for (final r in prototype.rpcs) {
      line.write(
        '|rpc.${r.name}:${r.codec.id}:${r.to.index}${r.delivery.index}',
      );
    }
    _schemaLines.add(line.toString());
  }

  /// Hash of every registered type's full field/rpc schema, order
  /// independent. Exchange at handshake; a mismatch means the builds
  /// disagree about the wire format.
  int get schemaHash {
    final sorted = List.of(_schemaLines)..sort();
    return fnv1a32(sorted.join('\n'));
  }

  int typeIdOf(Replica replica) => fnv1a32(replica.typeKey);

  String? typeKeyFor(int typeId) => _typeKeys[typeId];

  Replica? instantiate(int typeId) => _factories[typeId]?.call();
}

/// Convenience for building one-off payload codecs for RPC argument records.
final class StructCodec<T> implements Codec<T> {
  const StructCodec({
    required this.id,
    required void Function(ByteWriter, T) encode,
    required T Function(ByteReader) decode,
  }) : _encode = encode,
       _decode = decode;

  @override
  final String id;
  final void Function(ByteWriter, T) _encode;
  final T Function(ByteReader) _decode;

  @override
  void encode(ByteWriter w, T value) => _encode(w, value);

  @override
  T decode(ByteReader r) => _decode(r);

  @override
  bool equals(T a, T b) {
    final wa = ByteWriter(32);
    _encode(wa, a);
    final wb = ByteWriter(32);
    _encode(wb, b);
    final ba = wa.toBytes();
    final bb = wb.toBytes();
    if (ba.length != bb.length) return false;
    for (var i = 0; i < ba.length; i++) {
      if (ba[i] != bb[i]) return false;
    }
    return true;
  }
}

/// An empty-args codec for RPCs with no payload; call such endpoints with
/// null.
const Codec<Object?> voidCodec = _VoidCodec();

final class _VoidCodec implements Codec<Object?> {
  const _VoidCodec();

  @override
  String get id => 'void';

  @override
  void encode(ByteWriter w, Object? value) {}

  @override
  Object? decode(ByteReader r) => null;

  @override
  bool equals(Object? a, Object? b) => true;
}

/// Bytes helper shared by tests and engine adapters.
Uint8List encodeAllFields(Replica replica) {
  final w = ByteWriter(64);
  replica.encodeFields(w, 0xffffffff);
  return w.toBytes();
}
