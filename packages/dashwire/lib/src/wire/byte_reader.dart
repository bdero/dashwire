import 'dart:convert';
import 'dart:typed_data';

/// Reads little-endian fields sequentially from a byte buffer.
///
/// The exact mirror of ByteWriter. Reads past the end throw [FormatException]
/// so malformed remote data never becomes a range error deep in a codec.
final class ByteReader {
  ByteReader(Uint8List bytes)
    : _bytes = bytes,
      _data = ByteData.sublistView(bytes);

  final Uint8List _bytes;
  final ByteData _data;
  int _offset = 0;

  int get offset => _offset;
  int get remaining => _bytes.length - _offset;
  bool get isDone => remaining == 0;

  Never _fail(String field) => throw FormatException(
    '$field would read past the end (offset $_offset of ${_bytes.length})',
  );

  void _need(int count, String field) {
    if (remaining < count) _fail(field);
  }

  int readU8() {
    _need(1, 'u8');
    return _data.getUint8(_offset++);
  }

  int readU16() {
    _need(2, 'u16');
    final v = _data.getUint16(_offset, Endian.little);
    _offset += 2;
    return v;
  }

  int readU32() {
    _need(4, 'u32');
    final v = _data.getUint32(_offset, Endian.little);
    _offset += 4;
    return v;
  }

  int readI32() {
    _need(4, 'i32');
    final v = _data.getInt32(_offset, Endian.little);
    _offset += 4;
    return v;
  }

  double readF32() {
    _need(4, 'f32');
    final v = _data.getFloat32(_offset, Endian.little);
    _offset += 4;
    return v;
  }

  double readF64() {
    _need(8, 'f64');
    final v = _data.getFloat64(_offset, Endian.little);
    _offset += 8;
    return v;
  }

  /// LEB128 unsigned varint, 0 through 2^53 - 1. See ByteWriter.writeVarUint.
  int readVarUint() {
    var result = 0;
    var multiplier = 1;
    // 8 groups of 7 bits covers 2^53 - 1 (which encodes in 8 bytes).
    for (var i = 0; i < 8; i++) {
      final b = readU8();
      result += (b & 0x7f) * multiplier;
      if (b < 0x80) return result;
      multiplier *= 0x80;
    }
    throw const FormatException('varint longer than 8 bytes');
  }

  /// A view into the underlying buffer, not a copy.
  Uint8List readBytes(int length) {
    if (length < 0) _fail('bytes');
    _need(length, 'bytes');
    final view = Uint8List.sublistView(_bytes, _offset, _offset + length);
    _offset += length;
    return view;
  }

  Uint8List readLengthPrefixedBytes() => readBytes(readVarUint());

  String readString() => utf8.decode(readLengthPrefixedBytes());
}
