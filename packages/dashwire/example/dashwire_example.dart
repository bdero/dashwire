// Encode a message with the wire primitives, then round-trip a payload
// through the in-process loopback transport.
import 'package:dashwire/dashwire.dart';

Future<void> main() async {
  // Wire primitives are little-endian with varints and length-prefixed
  // strings, and every encoding has a byte-exact golden test.
  final writer = ByteWriter()
    ..writeString('dash')
    ..writeVarUint(300)
    ..writeF32(1.5);
  final bytes = writer.toBytes();

  final reader = ByteReader(bytes);
  print(reader.readString()); // dash
  print(reader.readVarUint()); // 300
  print(reader.readF32()); // 1.5

  // A loopback pair models two connected peers with reliable and unreliable
  // channels; the same code runs over WebSocket or UDP transports.
  final (client, server) = LoopbackConnection.pair();
  final sub = server.messages.listen((m) {
    print('server received ${m.payload.length} bytes on ${m.channel}');
  });

  client.send(Channel.reliable, bytes);
  await Future<void>.delayed(Duration.zero);

  await sub.cancel();
  await client.close();
}
