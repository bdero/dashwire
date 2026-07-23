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
  NetIdAllocator(this.session);

  /// A session from a cryptographic random source.
  NetIdAllocator.random() : session = Random.secure().nextInt(0x100000000);

  final int session;
  int _nextIndex = 0;

  NetId next() => NetId(session, _nextIndex++);
}
