import 'dart:typed_data';

import 'package:dashwire/dashwire.dart';
import 'package:test/test.dart';

void main() {
  test('delivers both directions with channel and order preserved', () async {
    final (a, b) = LoopbackConnection.pair();
    final received = <NetMessage>[];
    final sub = b.messages.listen(received.add);

    a.send(Channel.reliable, Uint8List.fromList([1]));
    a.send(Channel.unreliable, Uint8List.fromList([2]));
    a.send(Channel.reliable, Uint8List.fromList([3]));
    await Future<void>.delayed(Duration.zero);

    expect(received.map((m) => m.payload.single), [1, 2, 3]);
    expect(received.map((m) => m.channel), [
      Channel.reliable,
      Channel.unreliable,
      Channel.reliable,
    ]);

    final echo = a.messages.first;
    b.send(Channel.reliable, Uint8List.fromList([9]));
    expect((await echo).payload, [9]);
    await sub.cancel();
  });

  test('payloads are captured at send time', () async {
    final (a, b) = LoopbackConnection.pair();
    final buffer = Uint8List.fromList([1, 2, 3]);
    final first = b.messages.first;
    a.send(Channel.reliable, buffer);
    buffer[0] = 99;
    expect((await first).payload, [1, 2, 3]);
  });

  test('close propagates to both ends', () async {
    final (a, b) = LoopbackConnection.pair();
    final bMessages = b.messages.toList();
    await a.close();

    expect(a.isOpen, isFalse);
    expect(b.isOpen, isFalse);
    await a.done;
    await b.done;
    expect(await bMessages, isEmpty);
    expect(() => a.send(Channel.reliable, Uint8List(0)), throwsStateError);
    expect(() => b.send(Channel.reliable, Uint8List(0)), throwsStateError);
  });

  test('double close is a no-op', () async {
    final (a, b) = LoopbackConnection.pair();
    await a.close();
    await a.close();
    await b.close();
  });
}
