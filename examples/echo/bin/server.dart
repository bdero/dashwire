import 'dart:io';

import 'package:dashwire/dashwire.dart';
import 'package:dashwire/server.dart';

/// Echo server. WebSocket upgrades become sessions whose app payloads are
/// echoed back; plain GETs serve the compiled browser client from web/.
Future<void> main(List<String> args) async {
  final port = args.isEmpty ? 8080 : int.parse(args[0]);
  final webRoot = Directory.fromUri(Platform.script.resolve('../web'));
  final listener = SessionListener(
    schemaHash: echoSchemaHash,
    tickRate: 30,
    currentTick: () => 0,
  );

  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  print('echo server on http://localhost:$port (ws on the same port)');
  await for (final request in server) {
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      final session = await listener.accept(await upgradeWebSocket(request));
      if (session == null) continue;
      print('peer ${session.peerId} connected');
      session.appMessages.listen(
        (message) => session.sendApp(message.channel, message.payload),
        onDone: () => print('peer ${session.peerId} disconnected'),
      );
      continue;
    }
    final name = request.uri.path == '/' ? '/index.html' : request.uri.path;
    final file = File('${webRoot.path}$name');
    if (name.contains('..') || !file.existsSync()) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      continue;
    }
    request.response.headers.contentType = name.endsWith('.html')
        ? ContentType.html
        : ContentType('text', 'javascript');
    await request.response.addStream(file.openRead());
    await request.response.close();
  }
}

/// Shared schema hash for the echo demo protocol.
final int echoSchemaHash = fnv1a32('echo-example-v1');
