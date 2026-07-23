import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:arena_example/arena_shared.dart';
import 'package:dashwire/server.dart';
import 'package:dashwire_replication/dashwire_replication.dart';
import 'package:dashwire_replication/server.dart';

/// Arena lobby. Serves the web client, launches room isolates, and hands
/// joining players a room port via GET /join.
Future<void> main(List<String> args) async {
  final lobbyPort = args.isEmpty ? 8080 : int.parse(args[0]);
  final roomCount = args.length > 1 ? int.parse(args[1]) : 2;

  final pool = IsolateRoomPool();
  for (var i = 0; i < roomCount; i++) {
    final handle = await pool.launch(arenaRoom, roomId: 'room-$i');
    print('room ${handle.roomId} on port ${handle.port}');
  }
  final roomPorts = pool.rooms.values.map((r) => r.port).toList();
  var nextRoom = 0;

  final webRoot = Directory.fromUri(Platform.script.resolve('../web'));
  final server = await HttpServer.bind(InternetAddress.anyIPv4, lobbyPort);
  print('lobby on http://localhost:$lobbyPort');
  await for (final request in server) {
    if (request.uri.path == '/join') {
      final port = roomPorts[nextRoom++ % roomPorts.length];
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'port': port}));
      await request.response.close();
      continue;
    }
    final name = request.uri.path == '/' ? '/index.html' : request.uri.path;
    final file = File('${webRoot.path}$name');
    if (name.contains('..') || !file.existsSync()) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      continue;
    }
    request.response.headers.contentType = name.endsWith('.html')
        ? ContentType.html
        : ContentType('text', 'javascript');
    await request.response.addStream(file.openRead());
    await request.response.close();
  }
}

/// One arena room, runs inside a pool isolate.
Future<void> arenaRoom(RoomLaunch launch) async {
  final random = Random();
  final players = <int, ArenaPlayer>{};
  final pellets = <Pellet>[];
  late final Room room;

  void scatterPellet(Pellet pellet) {
    pellet.position.value = (
      random.nextDouble() * arenaWidth,
      random.nextDouble() * arenaHeight,
      0.0,
    );
  }

  room = Room(
    registry: arenaRegistry(),
    tickRate: arenaTickRate,
    onJoin: (session) {
      final player = ArenaPlayer()
        ..hue.value = random.nextInt(256)
        ..name.value = 'player ${session.peerId}'
        ..position.value = (
          random.nextDouble() * arenaWidth,
          random.nextDouble() * arenaHeight,
          0.0,
        );
      room.host.spawn(player, owner: session.peerId);
      players[session.peerId] = player;
      print('[${launch.roomId}] peer ${session.peerId} joined');
    },
    onLeave: (session) {
      final player = players.remove(session.peerId);
      if (player?.id != null) room.host.despawn(player!.id!);
      print('[${launch.roomId}] peer ${session.peerId} left');
    },
    onTick: (tick) {
      final dt = 1 / arenaTickRate;
      for (final player in players.values) {
        var (dx, dy, _) = player.input.value;
        final length = sqrt(dx * dx + dy * dy);
        if (length > 1) {
          dx /= length;
          dy /= length;
        }
        final (x, y, _) = player.position.value;
        player.position.value = (
          (x + dx * playerSpeed * dt).clamp(0.0, arenaWidth),
          (y + dy * playerSpeed * dt).clamp(0.0, arenaHeight),
          0.0,
        );
        for (final pellet in pellets) {
          final (px, py, _) = pellet.position.value;
          final (cx, cy, _) = player.position.value;
          final dxp = px - cx;
          final dyp = py - cy;
          if (dxp * dxp + dyp * dyp <
              (playerRadius + pelletRadius) * (playerRadius + pelletRadius)) {
            player.score.value += 1;
            scatterPellet(pellet);
          }
        }
      }
    },
  );

  for (var i = 0; i < pelletCount; i++) {
    final pellet = Pellet();
    scatterPellet(pellet);
    room.host.spawn(pellet, importance: 0.3);
    pellets.add(pellet);
  }

  final server = await WebSocketWireServer.bind(
    InternetAddress.anyIPv4,
    launch.requestedPort,
  );
  room
    ..accept(server.connections)
    ..start();
  launch.reportPort(server.port);
}
