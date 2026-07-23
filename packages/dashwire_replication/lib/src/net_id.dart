import 'dart:math';

import 'package:dashwire/dashwire.dart';

/// Network identity of a replicated object, a (session, index) pair.
///
/// Sessions are random 32-bit values distinguishing allocators, so ids
/// minted on different machines never collide without coordination. Both
/// halves stay within 32-bit lanes for dart2js.
final class NetId {
  const NetId(this.session, this.index);

  final int session;
  final int index;

  void encode(ByteWriter w) {
    w
      ..writeVarUint(session)
      ..writeVarUint(index);
  }

  static NetId decode(ByteReader r) => NetId(r.readVarUint(), r.readVarUint());

  @override
  bool operator ==(Object other) =>
      other is NetId && other.session == session && other.index == index;

  @override
  int get hashCode =>
      (session ^ index ^ ((index << 16) & 0xffffffff)) & 0x3fffffff;

  @override
  String toString() => '$session:$index';
}

/// Mints [NetId]s from one session.
final class NetIdAllocator {
  NetIdAllocator(this._session, {int startIndex = 0}) : _nextIndex = startIndex;

  /// A session from a cryptographic random source.
  NetIdAllocator.random()
    : _session = Random.secure().nextInt(0x100000000),
      _nextIndex = 0;

  int _session;
  int _nextIndex;

  int get session => _session;

  /// The index the next [next] call will mint.
  int get nextIndex => _nextIndex;

  /// Rewinds to persisted state (room hydration), so post-restore ids never
  /// collide with persisted ones.
  void restore({required int session, required int nextIndex}) {
    _session = session;
    _nextIndex = nextIndex;
  }

  NetId next() => NetId(_session, _nextIndex++);
}
