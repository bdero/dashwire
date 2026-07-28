import 'dart:typed_data';

import 'package:dashwire/dashwire.dart';
import 'package:dashwire_replication/dashwire_replication.dart';
import 'package:test/test.dart';

final class _Dummy extends Replica {
  @override
  String get typeKey => 'dummy';
}

ReplicaRegistry _registry() => ReplicaRegistry()..register(_Dummy.new);

void main() {
  test('input buffer stays converged through 150ms latency and loss', () async {
    final registry = _registry();

    int? clientPeer;
    var steadyTicks = 0;
    var starvedTicks = 0;

    late final Room room;
    room = Room(
      registry: registry,
      tickRate: 30,
      onJoin: (session) => clientPeer = session.peerId,
      onTick: (tick) {
        final peer = clientPeer;
        if (peer == null) return;
        room.input(peer, tick); // consume this tick's authoritative input
        // Measure only after the pipeline has warmed up.
        if (tick > 20) {
          steadyTicks++;
          if (room.host.inputStarved(peer)) starvedTicks++;
        }
      },
    );

    final (clientEnd, serverEnd) = LoopbackConnection.pair();
    final admitted = room.admit(serverEnd);
    final sim = SimulatorConnection(
      clientEnd,
      const SimulatedConditions(
        latency: Duration(milliseconds: 65),
        jitter: Duration(milliseconds: 20),
        unreliableLoss: 0.05,
        seed: 7,
      ),
    );
    final session = await connectSession(
      sim,
      schemaHash: registry.schemaHash,
      pingInterval: const Duration(milliseconds: 25),
    );
    await admitted;
    final client = ReplicationClient(registry: registry, session: session);

    // One real-time loop drives a client input and one server tick per step,
    // so send rate matches tick rate; the simulator delays and drops between.
    var counter = 0;
    final run = Stopwatch()..start();
    while (run.elapsedMilliseconds < 1800) {
      client.sendInput(Uint8List.fromList([counter++ & 0xff]));
      room.advance(1 / 30);
      await Future<void>.delayed(const Duration(milliseconds: 33));
    }

    // The whole loop ran end to end, the server applied a long run of inputs.
    expect(client.lastAppliedInputTick, greaterThan(20));
    // Applied progress keeps pace with the server (round trip plus a margin),
    // it does not fall behind and diverge.
    expect(room.currentTick - client.lastAppliedInputTick, lessThan(15));
    // The buffer rarely stalls once warmed up, the adaptive lead plus the
    // redundant tail absorb the loss and jitter.
    expect(starvedTicks / steadyTicks, lessThan(0.3));
    // The client still sees a cushion of buffered input on the server.
    expect(client.inputBufferDepth, greaterThanOrEqualTo(1));

    await room.stop();
    await client.session.close();
  });
}
