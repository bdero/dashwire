import 'dart:typed_data';

import 'package:dashwire/dashwire.dart';
import 'package:test/test.dart';

Uint8List _byte(int v) => Uint8List.fromList([v]);

void main() {
  test('delays delivery by roughly the configured latency', () async {
    final (a, b) = LoopbackConnection.pair();
    final sim = SimulatorConnection(
      a,
      const SimulatedConditions(latency: Duration(milliseconds: 50)),
    );
    final watch = Stopwatch()..start();
    final first = b.messages.first;
    sim.send(Channel.reliable, _byte(1));
    await first;
    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(45));
  });

  test('reliable ordering survives jitter', () async {
    final (a, b) = LoopbackConnection.pair();
    final sim = SimulatorConnection(
      a,
      const SimulatedConditions(
        latency: Duration(milliseconds: 5),
        jitter: Duration(milliseconds: 20),
        seed: 7,
      ),
    );
    final received = <int>[];
    final sub = b.messages.listen((m) => received.add(m.payload.single));
    for (var i = 0; i < 30; i++) {
      sim.send(Channel.reliable, _byte(i));
    }
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(received, List.generate(30, (i) => i));
    await sub.cancel();
  });

  test('unreliable loss is applied at the configured rate', () async {
    final (a, b) = LoopbackConnection.pair();
    final sim = SimulatorConnection(
      a,
      const SimulatedConditions(unreliableLoss: 0.3, seed: 42),
    );
    var received = 0;
    final sub = b.messages.listen((_) => received++);
    const sent = 500;
    for (var i = 0; i < sent; i++) {
      sim.send(Channel.unreliable, _byte(i % 256));
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(received, greaterThan(sent * 0.6));
    expect(received, lessThan(sent * 0.8));
    await sub.cancel();
  });

  test('duplicates arrive when configured', () async {
    final (a, b) = LoopbackConnection.pair();
    final sim = SimulatorConnection(
      a,
      const SimulatedConditions(unreliableDuplicate: 0.5, seed: 3),
    );
    var received = 0;
    final sub = b.messages.listen((_) => received++);
    for (var i = 0; i < 200; i++) {
      sim.send(Channel.unreliable, _byte(1));
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(received, greaterThan(220));
    await sub.cancel();
  });

  test('inbound deliveries are also delayed and closed cleanly', () async {
    final (a, b) = LoopbackConnection.pair();
    final sim = SimulatorConnection(
      a,
      const SimulatedConditions(latency: Duration(milliseconds: 20)),
    );
    final got = sim.messages.first;
    b.send(Channel.reliable, _byte(9));
    expect((await got).payload, [9]);
    await sim.close();
    expect(sim.isOpen, isFalse);
    await sim.done;
  });
}
