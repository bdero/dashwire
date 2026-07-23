import 'package:dashwire_udp/src/packet.dart';
import 'package:test/test.dart';

void main() {
  test('sequence comparison wraps', () {
    expect(seqGreater(1, 0), isTrue);
    expect(seqGreater(0, 1), isFalse);
    expect(seqGreater(0, 0xffff), isTrue);
    expect(seqGreater(0xffff, 0), isFalse);
    expect(seqGreater(0x8000, 0), isTrue);
    expect(seqGreater(0x8001, 0), isFalse);
    expect(seqNext(0xffff), 0);
    expect(seqDistance(0, 0xffff), 1);
  });

  test('ack tracker records history and rejects duplicates', () {
    final acks = AckTracker();
    expect(acks.record(0), isTrue);
    expect(acks.record(0), isFalse);
    expect(acks.record(2), isTrue);
    expect(acks.latest, 2);
    // Bit 0 is seq 1 (missing), bit 1 is seq 0 (received).
    expect(acks.historyBits, 0x2);
    expect(acks.record(1), isTrue);
    expect(acks.historyBits, 0x3);
    expect(acks.record(1), isFalse);
    expect(ackedSequences(acks.latest, acks.historyBits).toSet(), {0, 1, 2});
  });

  test('ack tracker survives wraparound', () {
    final acks = AckTracker();
    expect(acks.record(0xfffe), isTrue);
    expect(acks.record(0xffff), isTrue);
    expect(acks.record(0), isTrue);
    expect(acks.latest, 0);
    expect(ackedSequences(acks.latest, acks.historyBits).toSet(), {
      0xfffe,
      0xffff,
      0,
    });
  });

  test('large jumps clear the history window', () {
    final acks = AckTracker();
    acks.record(0);
    acks.record(100);
    expect(acks.latest, 100);
    expect(acks.historyBits, 0);
  });
}
