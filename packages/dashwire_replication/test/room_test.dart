import 'dart:typed_data';

import 'package:dashwire/dashwire.dart';
import 'package:dashwire_replication/dashwire_replication.dart';
import 'package:test/test.dart';

import 'test_replicas.dart';

Future<void> _pump([int rounds = 4]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

void main() {
  test('admits peers, ticks the simulation, and replicates', () async {
    final ticks = <int>[];
    final room = Room(registry: testRegistry(), onTick: ticks.add);
    final player = PlayerReplica();

    final (clientEnd, serverEnd) = LoopbackConnection.pair();
    final admitted = room.admit(serverEnd);
    final session = await connectSession(
      clientEnd,
      schemaHash: testRegistry().schemaHash,
      pingInterval: const Duration(seconds: 10),
    );
    final client = ReplicationClient(
      registry: testRegistry(),
      session: session,
    );
    expect(await admitted, isNotNull);

    room.host.spawn(player, owner: session.peerId);
    player.position.value = (3.0, 0.0, 0.0);
    room.advance(2 / 30); // Two fixed ticks.
    await _pump();

    expect(ticks, [0, 1]);
    expect(room.currentTick, 2);
    final remote = client.replicas.values.single as PlayerReplica;
    expect(remote.position.value.$1, closeTo(3, 0.01));
    await room.stop();
  });

  test('token verification gates admission', () async {
    final room = Room(
      registry: testRegistry(),
      verifyToken: (token) async => token.isNotEmpty && token[0] == 42,
    );
    final (badClient, badServer) = LoopbackConnection.pair();
    final badAdmit = room.admit(badServer);
    await expectLater(
      connectSession(
        badClient,
        schemaHash: testRegistry().schemaHash,
        authToken: Uint8List.fromList([1]),
      ),
      throwsA(isA<SessionRejected>()),
    );
    expect(await badAdmit, isNull);

    final (goodClient, goodServer) = LoopbackConnection.pair();
    final goodAdmit = room.admit(goodServer);
    await connectSession(
      goodClient,
      schemaHash: testRegistry().schemaHash,
      authToken: Uint8List.fromList([42]),
    );
    expect(await goodAdmit, isNotNull);
    await room.stop();
  });

  test('join and leave callbacks fire', () async {
    final joined = <int>[];
    final left = <int>[];
    final room = Room(
      registry: testRegistry(),
      onJoin: (s) => joined.add(s.peerId),
      onLeave: (s) => left.add(s.peerId),
    );
    final (clientEnd, serverEnd) = LoopbackConnection.pair();
    final admitted = room.admit(serverEnd);
    final session = await connectSession(
      clientEnd,
      schemaHash: testRegistry().schemaHash,
    );
    await admitted;
    expect(joined, [session.peerId]);
    await session.close();
    await _pump();
    expect(left, [session.peerId]);
    await room.stop();
  });

  test('snapshot and hydrate round trip through a store', () async {
    final roomA = Room(registry: testRegistry());
    final player = PlayerReplica()
      ..name.value = 'dash'
      ..score.value = 12
      ..position.value = (1.0, 2.0, 3.0);
    final playerId = roomA.host.spawn(player, owner: 7);
    roomA.host.spawn(DotReplica()..position.value = (9.0, 9.0, 9.0));

    final store = MemoryRoomStore();
    await store.save('alpha', roomA.snapshot());

    final roomB = Room(registry: testRegistry());
    roomB.hydrate((await store.load('alpha'))!);

    expect(roomB.host.replicas, hasLength(2));
    final restored = roomB.host.replicaById(playerId)! as PlayerReplica;
    expect(restored.owner, 7);
    expect(restored.name.value, 'dash');
    expect(restored.score.value, 12);
    expect(encodeAllFields(restored), encodeAllFields(player));

    // The restored allocator keeps minting non-colliding ids.
    final freshId = roomB.host.spawn(DotReplica());
    expect(roomB.host.replicas, hasLength(3));
    expect(freshId, isNot(playerId));
    expect(freshId.session, playerId.session);
    await roomA.stop();
    await roomB.stop();
  });

  test('the real-time pump advances ticks', () async {
    final room = Room(registry: testRegistry(), tickRate: 60)..start();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(room.currentTick, greaterThan(5));
    await room.stop();
  });
}
