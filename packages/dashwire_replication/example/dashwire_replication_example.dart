// Define a replicated type with quantized fields and permission axes, then
// read and write its values. In a game a ReplicationHost syncs these to
// clients under a byte budget; see the arena example in the repository.
import 'package:dashwire/dashwire.dart';
import 'package:dashwire_replication/dashwire_replication.dart';

final class Player extends Replica {
  Player() {
    name = rep('name', '', codec: Codecs.string, mode: SendMode.onChange);
    score = rep('score', 0, codec: Codecs.varUint, mode: SendMode.onChange);
    position = rep('position', (0.0, 0.0, 0.0), codec: Codecs.vec3(0.01));
    // Only the owning peer may write aim, and it is quantized on the wire.
    aim = rep(
      'aim',
      0.0,
      codec: Codecs.quantized(0.01),
      write: Authority.owner,
    );
  }

  @override
  String get typeKey => 'player';

  late final Rep<String> name;
  late final Rep<int> score;
  late final Rep<Vec3> position;
  late final Rep<double> aim;
}

void main() {
  // A registry maps type keys to constructors for spawn replication.
  ReplicaRegistry().register(Player.new);

  final player = Player()
    ..name.value = 'dash'
    ..score.value = 3
    ..position.value = (1.5, 0.0, -2.0);

  print('${player.name.value} scored ${player.score.value}');

  // vec3(0.01) keeps roughly centimeter precision on the wire.
  final codec = Codecs.vec3(0.01);
  final writer = ByteWriter();
  codec.encode(writer, player.position.value);
  final decoded = codec.decode(ByteReader(writer.toBytes()));
  print('position round-trips to $decoded in ${writer.length} bytes');
}
