import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dashwire/dashwire.dart';

/// Console client. Lines from stdin are echoed back by the server.
Future<void> main(List<String> args) async {
  final uri = Uri.parse(args.isEmpty ? 'ws://localhost:8080' : args[0]);
  final session = await connectSession(
    await connectWebSocket(uri),
    schemaHash: fnv1a32('echo-example-v1'),
  );
  print('connected as peer ${session.peerId}, type to echo');

  session.appMessages.listen((message) {
    print('echo(${message.channel.name}) ${utf8.decode(message.payload)}');
    print('rtt ${session.clock.rttMillis.toStringAsFixed(1)}ms');
  });

  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    session.sendApp(Channel.reliable, Uint8List.fromList(utf8.encode(line)));
  }
  await session.close();
}
