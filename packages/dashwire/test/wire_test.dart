import 'dart:typed_data';

import 'package:dashwire/dashwire.dart';
import 'package:test/test.dart';

void main() {
  group('ByteWriter golden bytes', () {
    test('fixed-width fields are little-endian', () {
      final w = ByteWriter()
        ..writeU8(0xab)
        ..writeU16(0xbeef)
        ..writeU32(0xdeadbeef)
        ..writeI32(-2)
        ..writeF32(1.5);
      expect(w.toBytes(), [
        0xab, //
        0xef, 0xbe, //
        0xef, 0xbe, 0xad, 0xde, //
        0xfe, 0xff, 0xff, 0xff, //
        0x00, 0x00, 0xc0, 0x3f, //
      ]);
    });

    test('varints', () {
      Uint8List enc(int v) => (ByteWriter()..writeVarUint(v)).toBytes();
      expect(enc(0), [0x00]);
      expect(enc(1), [0x01]);
      expect(enc(127), [0x7f]);
      expect(enc(128), [0x80, 0x01]);
      expect(enc(300), [0xac, 0x02]);
      expect(enc(0xffffffff), [0xff, 0xff, 0xff, 0xff, 0x0f]);
    });

    test('strings carry a varint byte-length prefix', () {
      expect((ByteWriter()..writeString('dash')).toBytes(), [
        0x04, 0x64, 0x61, 0x73, 0x68, //
      ]);
    });
  });

  group('round trips', () {
    test('mixed fields', () {
      final w = ByteWriter()
        ..writeU8(7)
        ..writeVarUint(9007199254740991)
        ..writeF64(-0.125)
        ..writeString('partyline')
        ..writeLengthPrefixedBytes([1, 2, 3])
        ..writeI32(-123456789);
      final r = ByteReader(w.toBytes());
      expect(r.readU8(), 7);
      expect(r.readVarUint(), 9007199254740991);
      expect(r.readF64(), -0.125);
      expect(r.readString(), 'partyline');
      expect(r.readLengthPrefixedBytes(), [1, 2, 3]);
      expect(r.readI32(), -123456789);
      expect(r.isDone, isTrue);
    });

    test('f32 quantizes to float precision', () {
      final w = ByteWriter()..writeF32(1.1);
      final v = ByteReader(w.toBytes()).readF32();
      expect(v, isNot(1.1));
      expect(v, closeTo(1.1, 1e-7));
    });

    test('writer reset reuses the buffer', () {
      final w = ByteWriter()..writeU32(1);
      w.reset();
      w.writeU8(9);
      expect(w.toBytes(), [9]);
    });
  });

  group('malformed input', () {
    test('reading past the end throws FormatException', () {
      final r = ByteReader((ByteWriter()..writeU8(1)).toBytes());
      r.readU8();
      expect(r.readU8, throwsFormatException);
      expect(r.readU32, throwsFormatException);
      expect(r.readVarUint, throwsFormatException);
    });

    test('truncated length prefix throws FormatException', () {
      final bytes = (ByteWriter()..writeVarUint(10)).toBytes();
      expect(ByteReader(bytes).readLengthPrefixedBytes, throwsFormatException);
    });

    test('unterminated varint throws FormatException', () {
      final bytes = Uint8List.fromList(List.filled(9, 0x80));
      expect(ByteReader(bytes).readVarUint, throwsFormatException);
    });
  });

  group('fnv1a32', () {
    test('matches reference vectors', () {
      expect(fnv1a32(''), 0x811c9dc5);
      expect(fnv1a32('a'), 0xe40c292c);
      expect(fnv1a32('foobar'), 0xbf9cf968);
    });

    test('stays within 32 bits', () {
      for (final s in ['dashwire', 'health', 'x' * 1000]) {
        final h = fnv1a32(s);
        expect(h, inInclusiveRange(0, 0xffffffff));
      }
    });
  });
}
