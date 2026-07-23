@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:dashwire/dashwire.dart';
import 'package:test/test.dart';

/// Runs a real WebSocket echo server in a VM hybrid isolate and connects to
/// it from the browser, proving the web client end to end.
const _serverCode = '''
import 'dart:typed_data';
import 'package:dashwire/server.dart';
import 'package:stream_channel/stream_channel.dart';

Future<void> hybridMain(StreamChannel<Object?> channel) async {
  final server = await WebSocketWireServer.bind('127.0.0.1', 0);
  server.connections.listen((connection) {
    connection.messages.listen(
      (message) => connection.send(message.channel, message.payload),
    );
  });
  channel.sink.add(server.port);
}
''';

void main() {
  test('browser client talks to a dart:io server', () async {
    final channel = spawnHybridCode(_serverCode);
    final port = await channel.stream.first as int;

    final connection = await connectWebSocket(
      Uri.parse('ws://127.0.0.1:$port'),
    );
    final echoes = connection.messages.take(2).toList();
    connection.send(Channel.reliable, Uint8List.fromList([1, 2, 3]));
    connection.send(Channel.unreliable, Uint8List.fromList([4]));
    final received = await echoes;
    expect(received[0].channel, Channel.reliable);
    expect(received[0].payload, [1, 2, 3]);
    expect(received[1].channel, Channel.unreliable);
    expect(received[1].payload, [4]);
    await connection.close();
  });

  test('a full session handshake works from the browser', () async {
    final channel = spawnHybridCode('''
import 'package:dashwire/dashwire.dart';
import 'package:dashwire/server.dart';
import 'package:stream_channel/stream_channel.dart';

Future<void> hybridMain(StreamChannel<Object?> channel) async {
  final server = await WebSocketWireServer.bind('127.0.0.1', 0);
  final listener = SessionListener(
    schemaHash: 0x7e57,
    tickRate: 30,
    currentTick: () => 123,
  );
  server.connections.listen((connection) async {
    final session = await listener.accept(connection);
    session?.appMessages.listen(
      (message) => session.sendApp(message.channel, message.payload),
    );
  });
  channel.sink.add(server.port);
}
''');
    final port = await channel.stream.first as int;
    final session = await connectSession(
      await connectWebSocket(Uri.parse('ws://127.0.0.1:$port')),
      schemaHash: 0x7e57,
      pingInterval: const Duration(milliseconds: 50),
    );
    expect(session.peerId, 2);

    final echo = session.appMessages.first;
    session.sendApp(Channel.reliable, Uint8List.fromList([5, 6]));
    expect((await echo).payload, [5, 6]);

    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(session.clock.isSynchronized, isTrue);
    expect(session.clock.rttMillis, greaterThan(0));
    await session.close();
  });
}
