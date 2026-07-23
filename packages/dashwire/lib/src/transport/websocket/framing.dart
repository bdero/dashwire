import 'dart:typed_data';

import '../transport.dart';

/// A WebSocket carries one ordered byte stream, so each binary frame is
/// prefixed with a channel byte. The unreliable channel degrades to reliable
/// delivery here; the [Channel] contract already permits that.
Uint8List frameForChannel(Channel channel, Uint8List payload) {
  final framed = Uint8List(payload.length + 1);
  framed[0] = channel.index;
  framed.setRange(1, framed.length, payload);
  return framed;
}

NetMessage? unframe(Uint8List framed) {
  if (framed.isEmpty || framed[0] >= Channel.values.length) return null;
  return NetMessage(
    Channel.values[framed[0]],
    Uint8List.sublistView(framed, 1),
  );
}
