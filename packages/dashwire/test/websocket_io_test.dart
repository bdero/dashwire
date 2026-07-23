@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:dashwire/dashwire.dart';
import 'package:dashwire/server.dart';
import 'package:test/test.dart';

void main() {
  test('io client and server exchange framed channels', () async {
    final server = await WebSocketWireServer.bind('127.0.0.1', 0);
    final serverSide = server.connections.first;
    final client = await connectWebSocket(
      Uri.parse('ws://127.0.0.1:${server.port}'),
    );
    final remote = await serverSide;

    final atServer = remote.messages.take(2).toList();
    client.send(Channel.reliable, Uint8List.fromList([1, 2]));
    client.send(Channel.unreliable, Uint8List.fromList([3]));
    final received = await atServer;
    expect(received[0].channel, Channel.reliable);
    expect(received[0].payload, [1, 2]);
    expect(received[1].channel, Channel.unreliable);
    expect(received[1].payload, [3]);

    final atClient = client.messages.first;
    remote.send(Channel.reliable, Uint8List.fromList([9]));
    expect((await atClient).payload, [9]);

    await client.close();
    await remote.done;
    await server.close();
  });

  test('a session runs over a real socket', () async {
    final server = await WebSocketWireServer.bind('127.0.0.1', 0);
    final listener = SessionListener(
      schemaHash: 0x51,
      tickRate: 20,
      currentTick: () => 7,
    );
    final acceptedFuture = server.connections.first.then(listener.accept);
    final client = await connectSession(
      await connectWebSocket(Uri.parse('ws://127.0.0.1:${server.port}')),
      schemaHash: 0x51,
    );
    final serverSession = (await acceptedFuture)!;

    expect(client.peerId, 2);
    final got = serverSession.appMessages.first;
    client.sendApp(Channel.reliable, Uint8List.fromList([42]));
    expect((await got).payload, [42]);

    await client.close();
    await server.close();
  });

  test('server close ends the client connection', () async {
    final server = await WebSocketWireServer.bind('127.0.0.1', 0);
    final serverSide = server.connections.first;
    final client = await connectWebSocket(
      Uri.parse('ws://127.0.0.1:${server.port}'),
    );
    await (await serverSide).close();
    await client.done;
    expect(client.isOpen, isFalse);
    await server.close();
  });
}
