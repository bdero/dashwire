import 'dart:typed_data';

import 'package:dashwire/dashwire.dart';
import 'package:dashwire_replication/src/sync/input.dart';
import 'package:test/test.dart';

Uint8List _bytes(List<int> b) => Uint8List.fromList(b);

void main() {
  group('input command wire format', () {
    test('encodeInputCommand golden bytes', () {
      final encoded = encodeInputCommand([
        (5, _bytes([0xaa])),
        (6, _bytes([0xbb, 0xcc])),
      ]);
      expect(encoded, [
        0x08, // MessageKind.inputCommand
        0x02, // count
        0x05, 0x01, 0xaa, // tick 5, len 1, payload
        0x06, 0x02, 0xbb, 0xcc, // tick 6, len 2, payload
      ]);
    });

    test('writeAck golden bytes', () {
      final buffer = ServerInputBuffer();
      final r = ByteReader(
        encodeInputCommand([
          (5, _bytes([1])),
          (6, _bytes([2])),
          (7, _bytes([3])),
          (8, _bytes([4])),
          (9, _bytes([5])),
          (10, _bytes([6])),
        ]),
      )..readU8();
      buffer.ingest(r);
      buffer.consume(7); // applied 7, leaves 8,9,10 buffered

      final w = ByteWriter(8);
      buffer.writeAck(w);
      expect(w.toBytes(), [
        0x09, // MessageKind.inputAck
        0x07, // lastAppliedTick
        0x03, // depth (8, 9, 10)
      ]);
    });
  });

  group('ServerInputBuffer', () {
    ServerInputBuffer ingest(
      ServerInputBuffer buffer,
      List<(int, Uint8List)> commands,
    ) {
      final r = ByteReader(encodeInputCommand(commands))..readU8();
      buffer.ingest(r);
      return buffer;
    }

    test('consume returns the exact tick and advances applied', () {
      final buffer = ingest(ServerInputBuffer(), [
        (5, _bytes([50])),
        (6, _bytes([60])),
      ]);
      expect(buffer.depth, 2);
      expect(buffer.consume(5), [50]);
      expect(buffer.lastAppliedTick, 5);
      expect(buffer.starvedLast, isFalse);
      expect(buffer.depth, 1); // 6 remains
      expect(buffer.consume(6), [60]);
      expect(buffer.depth, 0);
    });

    test('a missing tick holds the last input and flags starvation', () {
      final buffer = ingest(ServerInputBuffer(), [
        (5, _bytes([50])),
      ]);
      buffer.consume(5);
      expect(buffer.consume(6), [50]); // hold-last
      expect(buffer.starvedLast, isTrue);
      expect(buffer.lastAppliedTick, 5); // unchanged while holding
    });

    test('commands at or before the applied tick are ignored', () {
      final buffer = ingest(ServerInputBuffer(), [
        (5, _bytes([50])),
      ]);
      buffer.consume(5);
      ingest(buffer, [
        (4, _bytes([40])), // stale, dropped
        (7, _bytes([70])),
      ]);
      expect(buffer.depth, 1); // only 7
      expect(buffer.consume(7), [70]);
    });

    test('the window caps buffered future ticks, keeping the newest', () {
      final buffer = ingest(ServerInputBuffer(window: 3), [
        (1, _bytes([1])),
        (2, _bytes([2])),
        (3, _bytes([3])),
        (4, _bytes([4])),
        (5, _bytes([5])),
      ]);
      expect(buffer.depth, 3);
      expect(buffer.consume(1), isNull); // 1 and 2 were dropped
      expect(buffer.consume(3), [3]);
    });

    test('inactive until the first command arrives', () {
      final buffer = ServerInputBuffer();
      expect(buffer.isActive, isFalse);
      expect(buffer.consume(1), isNull);
      expect(buffer.starvedLast, isFalse); // not starving, just idle
      ingest(buffer, [
        (2, _bytes([2])),
      ]);
      expect(buffer.isActive, isTrue);
    });
  });
}
