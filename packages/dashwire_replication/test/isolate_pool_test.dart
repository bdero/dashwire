@TestOn('vm')
library;

import 'package:dashwire/dashwire.dart';
import 'package:dashwire/server.dart';
import 'package:dashwire_replication/dashwire_replication.dart';
import 'package:dashwire_replication/server.dart';
import 'package:test/test.dart';

import 'test_replicas.dart';

/// Room entry run inside the pool isolate, binds a WebSocket server, runs a
/// room with one dot, and reports its port.
Future<void> dotRoom(RoomLaunch launch) async {
  final server = await WebSocketWireServer.bind(
    '127.0.0.1',
    launch.requestedPort,
  );
  final room = Room(registry: testRegistry())..start();
  room.host.spawn(DotReplica()..position.value = (4.0, 5.0, 6.0));
  room.accept(server.connections);
  launch.reportPort(server.port);
}

void main() {
  test('a pooled room isolate serves clients end to end', () async {
    final pool = IsolateRoomPool();
    final handle = await pool.launch(dotRoom, roomId: 'alpha');
    expect(handle.port, greaterThan(0));

    final session = await connectSession(
      await connectWebSocket(Uri.parse('ws://127.0.0.1:${handle.port}')),
      schemaHash: testRegistry().schemaHash,
    );
    final client = ReplicationClient(
      registry: testRegistry(),
      session: session,
    );

    final sw = Stopwatch()..start();
    while (client.replicas.isEmpty && sw.elapsedMilliseconds < 3000) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final dot = client.replicas.values.single as DotReplica;
    expect(dot.position.value.$1, closeTo(4, 0.01));

    await session.close();
    pool.killAll();
    expect(pool.rooms, isEmpty);
  });

  test('duplicate room ids are refused', () async {
    final pool = IsolateRoomPool();
    final handle = await pool.launch(dotRoom, roomId: 'beta');
    expect(() => pool.launch(dotRoom, roomId: 'beta'), throwsStateError);
    handle.kill();
  });
}
