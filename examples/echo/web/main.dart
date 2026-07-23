import 'dart:convert';
import 'dart:typed_data';

import 'package:dashwire/dashwire.dart';

/// Browser client. Connects back to the serving host and echoes a counter;
/// output goes to the devtools console.
Future<void> main() async {
  final session = await connectSession(
    await connectWebSocket(Uri.parse('ws://${Uri.base.host}:${Uri.base.port}')),
    schemaHash: fnv1a32('echo-example-v1'),
  );
  print('connected as peer ${session.peerId}');

  session.appMessages.listen((message) {
    print(
      'echo ${utf8.decode(message.payload)} '
      '(rtt ${session.clock.rttMillis.toStringAsFixed(1)}ms)',
    );
  });

  var counter = 0;
  while (session.isOpen) {
    session.sendApp(
      Channel.reliable,
      Uint8List.fromList(utf8.encode('hello ${counter++}')),
    );
    await Future<void>.delayed(const Duration(seconds: 1));
  }
}
