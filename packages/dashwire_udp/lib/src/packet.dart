/// Datagram layout and u16 sequence arithmetic.
///
/// Every datagram starts with a magic byte and a kind. Payload and keepalive
/// datagrams carry a session id and piggybacked acks (latest reliable
/// sequence received plus a 32-bit history bitfield, the scheme described in
/// Gaffer On Games "Reliable Ordered Messages"). Sequence comparison wraps
/// per RFC 1982 serial number arithmetic.
library;

const int magicByte = 0xd5;

abstract final class PacketKind {
  static const int connectRequest = 1;
  static const int connectAccept = 2;
  static const int payload = 3;
  static const int keepalive = 4;
  static const int disconnect = 5;
}

abstract final class PayloadFlags {
  static const int unreliable = 1;
  static const int fragmented = 2;
}

/// True when u16 sequence [a] is newer than [b], wrap-aware.
bool seqGreater(int a, int b) =>
    (a > b && a - b <= 0x8000) || (a < b && b - a > 0x8000);

int seqNext(int s) => (s + 1) & 0xffff;

/// How many increments [a] is ahead of [b] (small non-negative distances).
int seqDistance(int a, int b) => (a - b) & 0xffff;

/// Tracks received reliable sequences and produces ack fields.
final class AckTracker {
  bool _any = false;
  int _latest = 0;
  int _history = 0;

  bool get hasReceived => _any;
  int get latest => _latest;
  int get historyBits => _history;

  /// Records [seq] as received. Returns false for duplicates.
  bool record(int seq) {
    if (!_any) {
      _any = true;
      _latest = seq;
      return true;
    }
    if (seq == _latest) return false;
    if (seqGreater(seq, _latest)) {
      final shift = seqDistance(seq, _latest);
      _history = shift >= 32
          ? 0
          : ((_history << shift) & 0xffffffff) | (1 << (shift - 1));
      _latest = seq;
      return true;
    }
    final back = seqDistance(_latest, seq);
    if (back > 32) return false;
    final bit = 1 << (back - 1);
    if (_history & bit != 0) return false;
    _history |= bit;
    return true;
  }
}

/// Expands ack fields into the acked sequence numbers.
Iterable<int> ackedSequences(int latest, int historyBits) sync* {
  yield latest;
  for (var i = 0; i < 32; i++) {
    if (historyBits & (1 << i) != 0) yield (latest - 1 - i) & 0xffff;
  }
}
