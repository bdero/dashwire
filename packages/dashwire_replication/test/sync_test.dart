import 'package:dashwire/dashwire.dart';
import 'package:dashwire_replication/dashwire_replication.dart';
import 'package:test/test.dart';

import 'test_replicas.dart';

Future<void> _pump([int rounds = 4]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

final class _Net {
  _Net(this.host, this.clients);

  final ReplicationHost host;
  final List<ReplicationClient> clients;
  int tick = 0;

  Future<void> step([int times = 1]) async {
    for (var i = 0; i < times; i++) {
      host.tick(++tick);
      await _pump();
      for (final client in clients) {
        client.flush();
      }
      await _pump();
    }
  }
}

Future<_Net> _network(
  int clientCount, {
  ReplicaRegistry Function()? registryFactory,
  HostConfig config = const HostConfig(),
}) async {
  final makeRegistry = registryFactory ?? testRegistry;
  final serverRegistry = makeRegistry();
  final host = ReplicationHost(registry: serverRegistry, config: config);
  final listener = SessionListener(
    schemaHash: serverRegistry.schemaHash,
    tickRate: 30,
    currentTick: () => 0,
  );
  final clients = <ReplicationClient>[];
  for (var i = 0; i < clientCount; i++) {
    final (clientEnd, serverEnd) = LoopbackConnection.pair();
    final accepted = listener.accept(serverEnd);
    final clientRegistry = makeRegistry();
    final session = await connectSession(
      clientEnd,
      schemaHash: clientRegistry.schemaHash,
      pingInterval: const Duration(seconds: 10),
    );
    host.attach((await accepted)!);
    clients.add(ReplicationClient(registry: clientRegistry, session: session));
  }
  return _Net(host, clients);
}

void main() {
  test('spawn carries initial and spawnOnly state to every client', () async {
    final net = await _network(2);
    final player = PlayerReplica()
      ..kind.value = 3
      ..name.value = 'dash'
      ..position.value = (1.0, 2.0, 3.0);
    final id = net.host.spawn(player, owner: net.clients[0].localPeerId);
    await net.step();

    for (final client in net.clients) {
      final remote = client.replicaById(id)! as PlayerReplica;
      expect(remote.kind.value, 3);
      expect(remote.name.value, 'dash');
      expect(remote.position.value.$1, closeTo(1, 0.01));
      expect(remote.owner, net.clients[0].localPeerId);
    }
  });

  test('onChange fields flush reliably, stream fields via snapshots', () async {
    final net = await _network(1);
    final player = PlayerReplica();
    final id = net.host.spawn(player);
    await net.step();

    player.score.value = 42;
    player.position.value = (5.0, 0.0, 0.0);
    await net.step();

    final remote = net.clients[0].replicaById(id)! as PlayerReplica;
    expect(remote.score.value, 42);
    expect(remote.position.value.$1, closeTo(5, 0.01));
  });

  test('acked state stops resending', () async {
    final net = await _network(1);
    final player = PlayerReplica();
    net.host.spawn(player);
    await net.step();

    player.position.value = (5.0, 0.0, 0.0);
    await net.step();
    expect(net.host.debugLastSnapshotBytes, greaterThan(0));

    // Ack has arrived; with no further changes nothing is snapshotted.
    await net.step();
    expect(net.host.debugLastSnapshotBytes, 0);
  });

  test('ownerOnly fields reach only the owner', () async {
    final net = await _network(2);
    final player = PlayerReplica();
    final id = net.host.spawn(player, owner: net.clients[0].localPeerId);
    await net.step();
    player.secret.value = 777;
    await net.step();

    final ownerSide = net.clients[0].replicaById(id)! as PlayerReplica;
    final otherSide = net.clients[1].replicaById(id)! as PlayerReplica;
    expect(ownerSide.secret.value, 777);
    expect(otherSide.secret.value, 0);
  });

  test('owner writes apply on the server and propagate, validated', () async {
    final net = await _network(2);
    final player = PlayerReplica();
    final id = net.host.spawn(player, owner: net.clients[0].localPeerId);
    await net.step();

    final ownerSide = net.clients[0].replicaById(id)! as PlayerReplica;
    ownerSide.aim.value = 1.5;
    await net.step(2);
    expect(player.aim.value, closeTo(1.5, 0.01));
    final otherSide = net.clients[1].replicaById(id)! as PlayerReplica;
    expect(otherSide.aim.value, closeTo(1.5, 0.01));

    // Out-of-range writes are rejected by the validator.
    ownerSide.aim.value = 10;
    await net.step(2);
    expect(player.aim.value, closeTo(1.5, 0.01));
  });

  test('non-owners cannot write owner fields', () async {
    final net = await _network(2);
    final player = PlayerReplica();
    final id = net.host.spawn(player, owner: net.clients[0].localPeerId);
    await net.step();

    final otherSide = net.clients[1].replicaById(id)! as PlayerReplica;
    otherSide.aim.value = 2.0; // Local-only; the server must refuse it.
    await net.step(2);
    expect(player.aim.value, 0);
  });

  test('rpcs route by target with ownership checks', () async {
    final net = await _network(2);
    final player = PlayerReplica();
    final id = net.host.spawn(player, owner: net.clients[0].localPeerId);
    await net.step();

    final ownerSide = net.clients[0].replicaById(id)! as PlayerReplica;
    final otherSide = net.clients[1].replicaById(id)! as PlayerReplica;

    ownerSide.fire.call(9);
    await _pump();
    expect(player.fired, [(net.clients[0].localPeerId, 9)]);

    otherSide.fire.call(8); // Not the owner; dropped server-side.
    await _pump();
    expect(player.fired, hasLength(1));

    player.boom.call(4);
    await _pump();
    expect(player.booms, [4]); // Server ran it locally too.
    expect(ownerSide.booms, [4]);
    expect(otherSide.booms, [4]);
  });

  test('spatial relevancy spawns and despawns with the view', () async {
    final net = await _network(1);
    final grid = SpatialGridFilter(cellSize: 16);
    net.host.filters.add(grid);
    final peer = net.clients[0].localPeerId;

    final dot = DotReplica()..position.value = (100.0, 0.0, 0.0);
    final id = net.host.spawn(dot, alwaysRelevant: false);
    grid.setPosition(id, 100, 0);
    grid.setView(peer, 0, 0, 50);
    await net.step();
    expect(net.clients[0].replicaById(id), isNull);

    grid.setView(peer, 80, 0, 50);
    await net.step();
    expect(net.clients[0].replicaById(id), isNotNull);

    grid.setView(peer, 0, 0, 50);
    await net.step();
    expect(net.clients[0].replicaById(id), isNull);
  });

  test('dependents follow their parent', () async {
    final net = await _network(1);
    final parent = DotReplica();
    final child = DotReplica();
    final parentId = net.host.spawn(parent, alwaysRelevant: false);
    final childId = net.host.spawn(child, alwaysRelevant: false);
    net.host.dependents[parentId] = {childId};

    await net.step();
    expect(net.clients[0].replicaById(childId), isNull);

    net.host.relevantForPeer[net.clients[0].localPeerId] = {parentId};
    await net.step();
    expect(net.clients[0].replicaById(parentId), isNotNull);
    expect(net.clients[0].replicaById(childId), isNotNull);
  });

  test('snapshots respect the byte budget and starve fairly', () async {
    const config = HostConfig(snapshotBytesPerTick: 256);
    final net = await _network(1, config: config);
    final dots = <DotReplica>[];
    for (var i = 0; i < 60; i++) {
      final dot = DotReplica();
      net.host.spawn(dot);
      dots.add(dot);
    }
    await net.step(2);

    for (var i = 0; i < 60; i++) {
      dots[i].position.value = (i + 1.0, 0.0, 0.0);
    }
    // One tick cannot carry 60 entries at this budget.
    await net.step();
    expect(net.host.debugLastSnapshotBytes, lessThanOrEqualTo(256 + 16));
    final firstWave = net.clients[0].replicas.values
        .whereType<DotReplica>()
        .where((d) => d.position.value.$1 != 0)
        .length;
    expect(firstWave, lessThan(60));

    // Accumulated priority drains the rest across later ticks.
    await net.step(12);
    final delivered = net.clients[0].replicas.values
        .whereType<DotReplica>()
        .where((d) => d.position.value.$1 != 0)
        .length;
    expect(delivered, 60);
  });

  test('200 moving entities converge within budget', () async {
    const config = HostConfig(snapshotBytesPerTick: 2048);
    final net = await _network(2, config: config);
    final dots = <DotReplica>[];
    for (var i = 0; i < 200; i++) {
      final dot = DotReplica()..position.value = (i * 1.0, 0.0, 0.0);
      net.host.spawn(dot);
      dots.add(dot);
    }
    await net.step(2);

    // 30 ticks of continuous movement.
    for (var t = 0; t < 30; t++) {
      for (var i = 0; i < 200; i++) {
        final (x, y, z) = dots[i].position.value;
        dots[i].position.value = (x + 0.1, y + (i.isEven ? 0.05 : -0.05), z);
      }
      await net.step();
      expect(net.host.debugLastSnapshotBytes, lessThanOrEqualTo(2048 + 16));
    }

    // Movement stops; eventual consistency drains the backlog.
    await net.step(30);
    for (final client in net.clients) {
      var matched = 0;
      for (final dot in dots) {
        final remote = client.replicaById(dot.id!)! as DotReplica;
        final local = dot.position.value;
        final synced = remote.position.value;
        if ((synced.$1 - local.$1).abs() < 0.006 &&
            (synced.$2 - local.$2).abs() < 0.006) {
          matched++;
        }
      }
      expect(matched, 200);
    }
  });

  test(
    'priority scale packs favored entities first under a tight budget',
    () async {
      const config = HostConfig(snapshotBytesPerTick: 20);
      final net = await _network(1, config: config);
      // Favor B strongly for this peer, the distance-falloff generalization.
      final peerId = net.clients[0].localPeerId;
      late final NetId idB;
      net.host.priorityScale = (peer, replica) =>
          replica.id == idB && peer == peerId ? 20.0 : 1.0;

      final a = DotReplica();
      final b = DotReplica();
      net.host.spawn(a);
      idB = net.host.spawn(b);
      await net.step(2);

      // Both move every tick; the budget fits only one entry per tick.
      for (var i = 0; i < 6; i++) {
        a.position.value = (i + 1.0, 0.0, 0.0);
        b.position.value = (i + 1.0, 0.0, 0.0);
        await net.step();
      }

      final clientA = net.clients[0].replicaById(a.id!) as DotReplica;
      final clientB = net.clients[0].replicaById(b.id!) as DotReplica;
      // B (favored) tracks the latest; A lags far behind under starvation.
      expect(clientB.position.value.$1, greaterThan(clientA.position.value.$1));
    },
  );
}
