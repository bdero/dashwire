/// Simulation schema shared verbatim by the server, the web client, and the
/// bot client.
library;

import 'package:dashwire_replication/dashwire_replication.dart';

const double arenaWidth = 800;
const double arenaHeight = 600;
const double playerSpeed = 180; // units/second
const double playerRadius = 14;
const double pelletRadius = 5;
const int pelletCount = 30;
const int arenaTickRate = 30;

final class ArenaPlayer extends Replica {
  ArenaPlayer() {
    hue = rep('hue', 0, codec: Codecs.u8, mode: SendMode.spawnOnly);
    name = rep('name', '', codec: Codecs.string, mode: SendMode.onChange);
    score = rep('score', 0, codec: Codecs.varUint, mode: SendMode.onChange);
    position = rep('position', (0.0, 0.0, 0.0), codec: Codecs.vec3(0.01));
    input = rep(
      'input',
      (0.0, 0.0, 0.0),
      codec: Codecs.vec3(0.05),
      write: Authority.owner,
      validate: (peer, v) => v.$1.abs() <= 1.05 && v.$2.abs() <= 1.05,
    );
  }

  @override
  String get typeKey => 'arena.player';

  late final Rep<int> hue;
  late final Rep<String> name;
  late final Rep<int> score;
  late final Rep<Vec3> position;

  /// Owner-written movement intent, a direction vector clamped to length 1
  /// server-side.
  late final Rep<Vec3> input;
}

final class Pellet extends Replica {
  Pellet() {
    position = rep('position', (0.0, 0.0, 0.0), codec: Codecs.vec3(0.01));
  }

  @override
  String get typeKey => 'arena.pellet';

  late final Rep<Vec3> position;
}

ReplicaRegistry arenaRegistry() => ReplicaRegistry()
  ..register(ArenaPlayer.new)
  ..register(Pellet.new);
