import 'dart:math';
import 'dart:typed_data';

import 'package:dashwire/dashwire.dart';

/// Three-component vector as a dependency-free record. Engine layers adapt
/// their own vector types at the boundary.
typedef Vec3 = (double, double, double);

/// Quaternion as (x, y, z, w).
typedef Quat = (double, double, double, double);

/// Encodes values of [T] for the wire.
///
/// [equals] compares at wire precision, two values that encode identically
/// must compare equal, so sub-resolution changes never mark fields dirty.
/// [id] feeds the schema hash; changing an encoding must change its id.
abstract interface class Codec<T> {
  void encode(ByteWriter w, T value);
  T decode(ByteReader r);
  bool equals(T a, T b);
  String get id;
}

final class _FnCodec<T> implements Codec<T> {
  const _FnCodec(this.id, this._encode, this._decode, [this._equals]);

  @override
  final String id;
  final void Function(ByteWriter, T) _encode;
  final T Function(ByteReader) _decode;
  final bool Function(T, T)? _equals;

  @override
  void encode(ByteWriter w, T value) => _encode(w, value);

  @override
  T decode(ByteReader r) => _decode(r);

  @override
  bool equals(T a, T b) => _equals?.call(a, b) ?? a == b;
}

int _zigzag(int v) => v >= 0 ? 2 * v : -2 * v - 1;

int _unzigzag(int n) => n.isEven ? n ~/ 2 : -(n + 1) ~/ 2;

int _quantize(double v, double resolution) => _zigzag((v / resolution).round());

double _dequantize(int q, double resolution) => _unzigzag(q) * resolution;

/// Built-in codecs.
abstract final class Codecs {
  static const Codec<int> varUint = _FnCodec(
    'varUint',
    _encVarUint,
    _decVarUint,
  );
  static const Codec<int> i32 = _FnCodec('i32', _encI32, _decI32);
  static const Codec<int> u8 = _FnCodec('u8', _encU8, _decU8);
  static const Codec<bool> boolean = _FnCodec('bool', _encBool, _decBool);
  static const Codec<double> f32 = _FnCodec('f32', _encF32, _decF32, _eqF32);
  static const Codec<double> f64 = _FnCodec('f64', _encF64, _decF64);
  static const Codec<String> string = _FnCodec(
    'string',
    _encString,
    _decString,
  );
  static const Codec<Uint8List> bytes = _FnCodec(
    'bytes',
    _encBytes,
    _decBytes,
    _eqBytes,
  );

  // Codec ids embed numeric parameters in exponential form, which every
  // compiler prints identically; plain toString renders 1.0 as "1.0" on
  // the VM but "1" under dart2js, silently splitting the schema hash
  // between a native host and a web client.
  static String _res(double resolution) => resolution.toStringAsExponential();

  /// A double quantized to multiples of [resolution] (zigzag varint).
  static Codec<double> quantized(double resolution) => _FnCodec(
    'q(${_res(resolution)})',
    (w, v) => w.writeVarUint(_quantize(v, resolution)),
    (r) => _dequantize(r.readVarUint(), resolution),
    (a, b) => _quantize(a, resolution) == _quantize(b, resolution),
  );

  /// A [Vec3] with each component quantized to [resolution].
  static Codec<Vec3> vec3(double resolution) => _FnCodec(
    'v3(${_res(resolution)})',
    (w, v) => w
      ..writeVarUint(_quantize(v.$1, resolution))
      ..writeVarUint(_quantize(v.$2, resolution))
      ..writeVarUint(_quantize(v.$3, resolution)),
    (r) => (
      _dequantize(r.readVarUint(), resolution),
      _dequantize(r.readVarUint(), resolution),
      _dequantize(r.readVarUint(), resolution),
    ),
    (a, b) =>
        _quantize(a.$1, resolution) == _quantize(b.$1, resolution) &&
        _quantize(a.$2, resolution) == _quantize(b.$2, resolution) &&
        _quantize(a.$3, resolution) == _quantize(b.$3, resolution),
  );

  /// A unit quaternion in smallest-three encoding, 2 bits pick the largest
  /// component, the other three quantize to 10 bits each, one u32 total.
  static const Codec<Quat> quat = _FnCodec(
    'quat10',
    _encQuat,
    _decQuat,
    _eqQuat,
  );

  static void _encVarUint(ByteWriter w, int v) => w.writeVarUint(v);
  static int _decVarUint(ByteReader r) => r.readVarUint();
  static void _encI32(ByteWriter w, int v) => w.writeI32(v);
  static int _decI32(ByteReader r) => r.readI32();
  static void _encU8(ByteWriter w, int v) => w.writeU8(v);
  static int _decU8(ByteReader r) => r.readU8();
  static void _encBool(ByteWriter w, bool v) => w.writeU8(v ? 1 : 0);
  static bool _decBool(ByteReader r) => r.readU8() != 0;
  static void _encF32(ByteWriter w, double v) => w.writeF32(v);
  static double _decF32(ByteReader r) => r.readF32();
  static bool _eqF32(double a, double b) => _f32(a) == _f32(b);
  static double _f32(double v) => (Float32List(1)..[0] = v)[0];
  static void _encF64(ByteWriter w, double v) => w.writeF64(v);
  static double _decF64(ByteReader r) => r.readF64();
  static void _encString(ByteWriter w, String v) => w.writeString(v);
  static String _decString(ByteReader r) => r.readString();
  static void _encBytes(ByteWriter w, Uint8List v) =>
      w.writeLengthPrefixedBytes(v);
  static Uint8List _decBytes(ByteReader r) =>
      Uint8List.fromList(r.readLengthPrefixedBytes());
  static bool _eqBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static int _packQuat(Quat q) {
    final components = [q.$1, q.$2, q.$3, q.$4];
    var largest = 0;
    for (var i = 1; i < 4; i++) {
      if (components[i].abs() > components[largest].abs()) largest = i;
    }
    // Negate so the dropped component is non-negative; q and -q are the
    // same rotation.
    final sign = components[largest] < 0 ? -1.0 : 1.0;
    var packed = largest;
    var shift = 2;
    // Remaining components lie in [-1/sqrt2, 1/sqrt2].
    const limit = 0.7071068;
    for (var i = 0; i < 4; i++) {
      if (i == largest) continue;
      final scaled = (components[i] * sign / limit).clamp(-1.0, 1.0);
      final q10 = ((scaled + 1) * 511.5).round().clamp(0, 1023);
      packed |= (q10 << shift) & 0xffffffff;
      shift += 10;
    }
    return packed;
  }

  static void _encQuat(ByteWriter w, Quat q) => w.writeU32(_packQuat(q));

  static Quat _decQuat(ByteReader r) {
    final packed = r.readU32();
    final largest = packed & 0x3;
    const limit = 0.7071068;
    final components = List<double>.filled(4, 0);
    var shift = 2;
    var sumSquares = 0.0;
    for (var i = 0; i < 4; i++) {
      if (i == largest) continue;
      final q10 = (packed >> shift) & 0x3ff;
      final value = (q10 / 511.5 - 1) * limit;
      components[i] = value;
      sumSquares += value * value;
      shift += 10;
    }
    final rest = 1 - sumSquares;
    components[largest] = rest > 0 ? sqrt(rest) : 0;
    return (components[0], components[1], components[2], components[3]);
  }

  static bool _eqQuat(Quat a, Quat b) => _packQuat(a) == _packQuat(b);
}
