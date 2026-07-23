import 'dart:typed_data';

import 'package:dashwire/dashwire.dart';
import 'package:test/test.dart';

SessionListener _listener({
  int schemaHash = 0xabc,
  Future<bool> Function(Uint8List)? verify,
  int Function()? currentTick,
}) => SessionListener(
  schemaHash: schemaHash,
  tickRate: 30,
  currentTick: currentTick ?? () => 0,
  verifyToken: verify,
);

void main() {
  test('handshake assigns peer ids and carries app traffic', () async {
    final (clientEnd, serverEnd) = LoopbackConnection.pair();
    final serverSessionFuture = _listener().accept(serverEnd);
    final client = await connectSession(clientEnd, schemaHash: 0xabc);
    final server = (await serverSessionFuture)!;

    expect(client.peerId, 2);
    expect(server.peerId, 2);
    expect(client.tickRate, 30);
    expect(client.isClient, isTrue);
    expect(server.isClient, isFalse);

    final atServer = server.appMessages.first;
    client.sendApp(Channel.reliable, Uint8List.fromList([1, 2, 3]));
    expect((await atServer).payload, [1, 2, 3]);

    final atClient = client.appMessages.first;
    server.sendApp(Channel.unreliable, Uint8List.fromList([4]));
    final received = await atClient;
    expect(received.payload, [4]);
    expect(received.channel, Channel.unreliable);
    await client.close();
  });

  test('peer ids increment per connection', () async {
    final listener = _listener();
    final (c1, s1) = LoopbackConnection.pair();
    final (c2, s2) = LoopbackConnection.pair();
    final f1 = listener.accept(s1);
    final f2 = listener.accept(s2);
    final a = await connectSession(c1, schemaHash: 0xabc);
    final b = await connectSession(c2, schemaHash: 0xabc);
    await f1;
    await f2;
    expect({a.peerId, b.peerId}, {2, 3});
  });

  test('schema mismatch rejects with SessionRejected', () async {
    final (clientEnd, serverEnd) = LoopbackConnection.pair();
    final accept = _listener(schemaHash: 1).accept(serverEnd);
    await expectLater(
      connectSession(clientEnd, schemaHash: 2),
      throwsA(
        isA<SessionRejected>().having(
          (e) => e.code,
          'code',
          RejectCode.schemaMismatch,
        ),
      ),
    );
    expect(await accept, isNull);
  });

  test('failed auth rejects', () async {
    final (clientEnd, serverEnd) = LoopbackConnection.pair();
    final accept = _listener(verify: (t) async => false).accept(serverEnd);
    await expectLater(
      connectSession(
        clientEnd,
        schemaHash: 0xabc,
        authToken: Uint8List.fromList([1]),
      ),
      throwsA(
        isA<SessionRejected>().having(
          (e) => e.code,
          'code',
          RejectCode.authFailed,
        ),
      ),
    );
    expect(await accept, isNull);
  });

  test('token is delivered to the verifier', () async {
    final (clientEnd, serverEnd) = LoopbackConnection.pair();
    Uint8List? seen;
    final accept = _listener(
      verify: (t) async {
        seen = t;
        return true;
      },
    ).accept(serverEnd);
    await connectSession(
      clientEnd,
      schemaHash: 0xabc,
      authToken: Uint8List.fromList([9, 8, 7]),
    );
    await accept;
    expect(seen, [9, 8, 7]);
  });

  test('closing one side completes both sessions', () async {
    final (clientEnd, serverEnd) = LoopbackConnection.pair();
    final accept = _listener().accept(serverEnd);
    final client = await connectSession(clientEnd, schemaHash: 0xabc);
    final server = (await accept)!;
    await server.close();
    await client.done;
    expect(client.isOpen, isFalse);
  });

  test('clock converges through latency, jitter, and loss', () async {
    final (clientEnd, serverEnd) = LoopbackConnection.pair();
    var tick = 0;
    final accept = _listener(currentTick: () => tick).accept(serverEnd);
    final sim = SimulatorConnection(
      clientEnd,
      const SimulatedConditions(
        latency: Duration(milliseconds: 40),
        jitter: Duration(milliseconds: 15),
        unreliableLoss: 0.05,
        seed: 11,
      ),
    );
    final client = await connectSession(
      sim,
      schemaHash: 0xabc,
      pingInterval: const Duration(milliseconds: 25),
    );
    await accept;

    // Advance the server tick on a real timeline so tick estimates move.
    final ticker = Stopwatch()..start();
    while (ticker.elapsedMilliseconds < 700) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      tick = ticker.elapsedMilliseconds * 30 ~/ 1000;
    }

    final clock = client.clock;
    expect(clock.isSynchronized, isTrue);
    // True one-way latency is 40-55ms, so RTT should hover near 80-110.
    expect(clock.rttMillis, greaterThan(60));
    expect(clock.rttMillis, lessThan(140));
    // Server and client share a process, so true offset is near zero.
    final skewMillis =
        (clock.serverMicrosAt(defaultNowMicros()) - defaultNowMicros()).abs() /
        1000;
    expect(skewMillis, lessThan(30));
    // The input tick leads the estimated server tick.
    final nowTicks = clock.serverTicksAt(defaultNowMicros());
    expect(clock.inputTickAt(defaultNowMicros()), greaterThan(nowTicks));
    await client.close();
  });
}
