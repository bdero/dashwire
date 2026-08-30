import 'package:dashwire_replication/dashwire_replication.dart';

final class PlayerReplica extends Replica {
  PlayerReplica() {
    kind = rep('kind', 0, codec: Codecs.u8, mode: SendMode.spawnOnly);
    name = rep('name', '', codec: Codecs.string, mode: SendMode.onChange);
    score = rep('score', 0, codec: Codecs.varUint, mode: SendMode.onChange);
    position = rep('position', (0.0, 0.0, 0.0), codec: Codecs.vec3(0.01));
    secret = rep(
      'secret',
      0,
      codec: Codecs.varUint,
      mode: SendMode.onChange,
      read: ReadScope.ownerOnly,
    );
    aim = rep(
      'aim',
      0,
      codec: Codecs.quantized(0.01),
      write: Authority.owner,
      validate: (peer, v) => v >= -4 && v <= 4,
    );
    fire = rpc(
      'fire',
      codec: Codecs.varUint,
      to: RpcTarget.server,
      onCall: (from, seed) => fired.add((from, seed)),
    );
    boom = rpc(
      'boom',
      codec: Codecs.varUint,
      to: RpcTarget.all,
      onCall: (from, value) => booms.add(value),
    );
    hit = rpc(
      'hit',
      codec: Codecs.varUint,
      to: RpcTarget.notOwner,
      onCall: (from, value) => hits.add(value),
    );
    quiet = rpc(
      'quiet',
      codec: Codecs.varUint,
      to: RpcTarget.others,
      onCall: (from, value) => quiets.add(value),
    );
  }

  @override
  String get typeKey => 'player';

  late final Rep<int> kind;
  late final Rep<String> name;
  late final Rep<int> score;
  late final Rep<Vec3> position;
  late final Rep<int> secret;
  late final Rep<double> aim;
  late final RpcEndpoint<int> fire;
  late final RpcEndpoint<int> boom;
  late final RpcEndpoint<int> hit;
  late final RpcEndpoint<int> quiet;

  final fired = <(int, int)>[];
  final booms = <int>[];
  final hits = <int>[];
  final quiets = <int>[];
}

final class DotReplica extends Replica {
  DotReplica() {
    position = rep('position', (0.0, 0.0, 0.0), codec: Codecs.vec3(0.01));
  }

  @override
  String get typeKey => 'dot';

  late final Rep<Vec3> position;
}

ReplicaRegistry testRegistry() => ReplicaRegistry()
  ..register(PlayerReplica.new)
  ..register(DotReplica.new);
