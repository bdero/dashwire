import 'dart:convert';
import 'dart:typed_data';

/// Grows a little-endian byte buffer one field at a time.
///
/// Integer encodings stay within 32-bit lanes so the emitted bytes are
/// identical on the VM, dart2js, and dart2wasm. [writeVarUint] additionally
/// accepts values up to 2^53 - 1 by avoiding bitwise ops entirely.
final class ByteWriter {
  ByteWriter([int initialCapacity = 64])
    : _bytes = Uint8List(initialCapacity < 8 ? 8 : initialCapacity) {
    _data = ByteData.sublistView(_bytes);
  }

  Uint8List _bytes;
  late ByteData _data;
  int _length = 0;

  /// Bytes written so far.
  int get length => _length;

  void _ensure(int extra) {
    final needed = _length + extra;
    if (needed <= _bytes.length) return;
    var capacity = _bytes.length * 2;
    while (capacity < needed) {
      capacity *= 2;
    }
    _bytes = Uint8List(capacity)..setRange(0, _length, _bytes);
    _data = ByteData.sublistView(_bytes);
  }

  void writeU8(int value) {
    _ensure(1);
    _data.setUint8(_length, value);
    _length += 1;
  }

  void writeU16(int value) {
    _ensure(2);
    _data.setUint16(_length, value, Endian.little);
    _length += 2;
  }

  void writeU32(int value) {
    _ensure(4);
    _data.setUint32(_length, value, Endian.little);
    _length += 4;
  }

  void writeI32(int value) {
    _ensure(4);
    _data.setInt32(_length, value, Endian.little);
    _length += 4;
  }

  void writeF32(double value) {
    _ensure(4);
    _data.setFloat32(_length, value, Endian.little);
    _length += 4;
  }

  void writeF64(double value) {
    _ensure(8);
    _data.setFloat64(_length, value, Endian.little);
    _length += 8;
  }

  /// LEB128 unsigned varint (7 data bits per byte, high bit continues).
  ///
  /// Accepts 0 through 2^53 - 1. Uses arithmetic rather than shifts so
  /// values past 2^32 encode correctly under dart2js number semantics.
  void writeVarUint(int value) {
    assert(value >= 0, 'varints are unsigned');
    var v = value;
    while (v >= 0x80) {
      writeU8(0x80 | (v % 0x80));
      v ~/= 0x80;
    }
    writeU8(v);
  }

  void writeBytes(List<int> bytes) {
    _ensure(bytes.length);
    _bytes.setRange(_length, _length + bytes.length, bytes);
    _length += bytes.length;
  }

  /// Varint length prefix followed by the raw bytes.
  void writeLengthPrefixedBytes(List<int> bytes) {
    writeVarUint(bytes.length);
    writeBytes(bytes);
  }

  /// UTF-8 with a varint byte-length prefix.
  void writeString(String value) =>
      writeLengthPrefixedBytes(utf8.encode(value));

  /// Copies the written bytes into a right-sized list.
  ///
  /// The writer stays usable; call [reset] to reuse the buffer for the next
  /// message instead of allocating a new writer.
  Uint8List toBytes() =>
      Uint8List.fromList(Uint8List.sublistView(_bytes, 0, _length));

  /// Rewinds to empty without shrinking the buffer.
  void reset() => _length = 0;
}
