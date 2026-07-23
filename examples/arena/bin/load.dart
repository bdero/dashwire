import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:arena_example/arena_shared.dart';
import 'package:dashwire/dashwire.dart';
import 'package:dashwire_replication/dashwire_replication.dart';

/// Thin-client load harness. Bots join through the lobby, walk randomly,
/// and verify they observe other players moving. Exits non-zero on failure,
/// usable as an end-to-end smoke test.
Future<void> main(List<String> args) async {
  final lobby = Uri.parse(args.isEmpty ? 'http://localhost:8080' : args[0]);
  final botCount = args.length > 1 ? int.parse(args[1]) : 8;
  final seconds = args.length > 2 ? int.parse(args[2]) : 10;

  final http = HttpClient();
  final random = Random();
  final bots = <ReplicationClient>[];
  for (var i = 0; i < botCount; i++) {
    final joinRequest = await http.getUrl(lobby.resolve('/join'));
    final joinResponse = await joinRequest.close();
    final port =
        (jsonDecode(await joinResponse.transform(utf8.decoder).join())
                as Map<String, Object?>)['port']
            as int;
    final session = await connectSession(
      await connectWebSocket(Uri.parse('ws://${lobby.host}:$port')),
      schemaHash: arenaRegistry().schemaHash,
    );
    bots.add(ReplicationClient(registry: arenaRegistry(), session: session));
  }
  print('$botCount bots connected');

  final movedIds = <NetId>{};
  for (final bot in bots) {
    void watch(Replica replica) {
      if (replica is ArenaPlayer) {
        replica.position.onChanged((_, _) => movedIds.add(replica.id!));
      }
    }

    bot.replicas.values.forEach(watch);
  }
  // Also watch late spawns.
  final watchedBots = <ReplicationClient, Set<NetId>>{
    for (final b in bots) b: {},
  };

  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(deadline)) {
    for (final bot in bots) {
      final me = bot.replicas.values
          .whereType<ArenaPlayer>()
          .where((p) => p.owner == bot.localPeerId)
          .firstOrNull;
      me?.input.value = (
        random.nextDouble() * 2 - 1,
        random.nextDouble() * 2 - 1,
        0.0,
      );
      bot.flush();
      final watched = watchedBots[bot]!;
      for (final replica in bot.replicas.values) {
        if (replica is ArenaPlayer && watched.add(replica.id!)) {
          replica.position.onChanged((_, _) => movedIds.add(replica.id!));
        }
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }

  final seen = bots
      .map((b) => b.replicas.values.whereType<ArenaPlayer>().length)
      .toList();
  print('players visible per bot: $seen');
  print('players observed moving: ${movedIds.length}');
  for (final bot in bots) {
    print(
      'bot ${bot.localPeerId} rtt '
      '${bot.session.clock.rttMillis.toStringAsFixed(1)}ms, '
      '${bot.replicas.length} replicas',
    );
    await bot.session.close();
  }
  http.close();

  // Each room got roughly botCount/roomCount bots; every bot must at least
  // see itself and observe movement.
  final failed =
      seen.any((count) => count < 1) || movedIds.length < botCount ~/ 2;
  if (failed) {
    print('LOAD CHECK FAILED');
    exitCode = 1;
  } else {
    print('LOAD CHECK PASSED');
  }
}
