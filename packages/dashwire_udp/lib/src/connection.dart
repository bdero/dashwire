import 'dart:async';
import 'dart:typed_data';

import 'package:dashwire/dashwire.dart';

import 'packet.dart';

/// Tuning knobs shared by the client and server.
final class UdpConfig {
  const UdpConfig({
    this.maxPayloadBytes = 1150,
    this.resendInterval = const Duration(milliseconds: 100),
    this.keepaliveInterval = const Duration(milliseconds: 250),
    this.timeout = const Duration(seconds: 5),
    this.maxUnacked = 512,
    this.connectRetryInterval = const Duration(milliseconds: 250),
    this.connectTimeout = const Duration(seconds: 5),
    this.debugDropOutboundPayload,
  });

  /// Largest payload carried in one datagram before fragmentation.
  final int maxPayloadBytes;

  /// How often unacked reliable datagrams are resent.
  final Duration resendInterval;

  /// Idle interval after which an ack-carrying keepalive is sent.
  final Duration keepaliveInterval;

  /// Silence after which the connection is considered dead.
  final Duration timeout;

  /// Unacked reliable datagram ceiling; exceeding it closes the connection
  /// rather than buffering without bound.
  final int maxUnacked;

  final Duration connectRetryInterval;
  final Duration connectTimeout;

  /// Test seam. When set, payload/keepalive datagrams for which this returns
  /// true are silently dropped before hitting the socket.
  final bool Function()? debugDropOutboundPayload;
}

class _OutgoingReliable {
  _OutgoingReliable(this.datagram);

  final Uint8List datagram;
  int lastSentMicros = 0;
}

class _Reassembly {
  _Reassembly(this.count) : parts = List<Uint8List?>.filled(count, null);

  final int count;
  final List<Uint8List?> parts;
  int received = 0;
  int createdMicros = 0;
}

/// One established UDP connection.
///
/// Shared by the client (owning its socket) and the server (multiplexing one
/// socket across peers); the owner injects a raw datagram send function and
/// feeds inbound datagrams to [handleDatagram].
final class UdpConnection implements WireConnection {
  UdpConnection({
    required this.sessionId,
    required void Function(Uint8List datagram) sendDatagram,
    required this.config,
    NowMicros now = defaultNowMicros,
    void Function(UdpConnection)? onClosed,
  }) : _sendDatagram = sendDatagram,
       _now = now,
       _onClosed = onClosed {
    _lastReceivedMicros = _now();
    final tickInterval = Duration(
      microseconds: config.resendInterval.inMicroseconds ~/ 2,
    );
    _timer = Timer.periodic(tickInterval, (_) => _housekeep());
  }

  final int sessionId;
  final UdpConfig config;
  final void Function(Uint8List) _sendDatagram;
  final NowMicros _now;
  final void Function(UdpConnection)? _onClosed;

  final _messages = StreamController<NetMessage>();
  final _done = Completer<void>();
  Timer? _timer;
  bool _open = true;

  int _lastReceivedMicros = 0;
  int _lastSentMicros = 0;

  // Reliable sending.
  int _nextReliableSeq = 0;
  final Map<int, _OutgoingReliable> _unacked = {};

  // Reliable receiving, ordered delivery.
  final AckTracker _acks = AckTracker();
  int _expectedReliableSeq = 0;
  final Map<int, Uint8List> _reliableHeld = {};

  // Unreliable sequencing, newest wins.
  int _nextUnreliableSeq = 0;
  int _latestUnreliableSeq = 0;
  bool _anyUnreliable = false;

  // Fragment reassembly, keyed by fragment id.
  int _nextFragId = 0;
  final Map<int, _Reassembly> _reassembly = {};

  @override
  bool get isOpen => _open;

  @override
  Stream<NetMessage> get messages => _messages.stream;

  @override
  Future<void> get done => _done.future;

  int get debugUnackedCount => _unacked.length;

  @override
  void send(Channel channel, Uint8List payload) {
    if (!_open) throw StateError('send on a closed connection');
    final limit = config.maxPayloadBytes;
    if (payload.length <= limit) {
      _sendPiece(channel, payload, null);
      return;
    }
    final fragId = _nextFragId = (_nextFragId + 1) & 0xffff;
    final count = (payload.length + limit - 1) ~/ limit;
    if (count > 255) {
      throw ArgumentError('payload too large (${payload.length} bytes)');
    }
    for (var i = 0; i < count; i++) {
      final start = i * limit;
      final end = start + limit > payload.length
          ? payload.length
          : start + limit;
      _sendPiece(channel, Uint8List.sublistView(payload, start, end), (
        fragId,
        i,
        count,
      ));
    }
  }

  void _sendPiece(Channel channel, Uint8List piece, (int, int, int)? frag) {
    final reliable = channel == Channel.reliable;
    final int seq;
    if (reliable) {
      seq = _nextReliableSeq;
      _nextReliableSeq = seqNext(seq);
    } else {
      seq = _nextUnreliableSeq;
      _nextUnreliableSeq = seqNext(seq);
    }

    final w = ByteWriter(piece.length + 24)
      ..writeU8(magicByte)
      ..writeU8(PacketKind.payload)
      ..writeU32(sessionId);
    _writeAcks(w);
    var flags = reliable ? 0 : PayloadFlags.unreliable;
    if (frag != null) flags |= PayloadFlags.fragmented;
    w
      ..writeU8(flags)
      ..writeU16(seq);
    if (frag != null) {
      w
        ..writeU16(frag.$1)
        ..writeU8(frag.$2)
        ..writeU8(frag.$3);
    }
    w.writeBytes(piece);
    final datagram = w.toBytes();

    if (reliable) {
      if (_unacked.length >= config.maxUnacked) {
        _fail();
        throw StateError('reliable send queue overflow');
      }
      _unacked[seq] = _OutgoingReliable(datagram)..lastSentMicros = _now();
    }
    _transmit(datagram);
  }

  // Ack section, a cumulative ack (the ordered-delivery high-water mark,
  // everything before it is received) plus the latest-window bitfield. The
  // cumulative ack drains senders whose in-flight span exceeds the 33-wide
  // bitfield window.
  void _writeAcks(ByteWriter w) {
    w
      ..writeU8(_acks.hasReceived ? 1 : 0)
      ..writeU16(_expectedReliableSeq)
      ..writeU16(_acks.latest)
      ..writeU32(_acks.historyBits);
  }

  void _transmit(Uint8List datagram) {
    _lastSentMicros = _now();
    if (config.debugDropOutboundPayload?.call() ?? false) return;
    _sendDatagram(datagram);
  }

  /// Feeds one inbound datagram, already stripped of nothing (full bytes).
  void handleDatagram(Uint8List datagram) {
    if (!_open) return;
    final r = ByteReader(datagram);
    if (r.readU8() != magicByte) return;
    final kind = r.readU8();
    if (r.readU32() != sessionId) return;
    _lastReceivedMicros = _now();

    switch (kind) {
      case PacketKind.disconnect:
        _fail();
      case PacketKind.keepalive:
        _readAcks(r);
      case PacketKind.payload:
        _readAcks(r);
        final flags = r.readU8();
        final seq = r.readU16();
        (int, int, int)? frag;
        if (flags & PayloadFlags.fragmented != 0) {
          frag = (r.readU16(), r.readU8(), r.readU8());
        }
        final piece = Uint8List.fromList(r.readBytes(r.remaining));
        if (flags & PayloadFlags.unreliable != 0) {
          _handleUnreliable(seq, piece, frag);
        } else {
          _handleReliable(seq, piece, frag);
        }
    }
  }

  void _readAcks(ByteReader r) {
    final hasAcks = r.readU8() != 0;
    final cumulative = r.readU16();
    final latest = r.readU16();
    final bits = r.readU32();
    _unacked.removeWhere((seq, _) => seqGreater(cumulative, seq));
    if (!hasAcks) return;
    for (final seq in ackedSequences(latest, bits)) {
      _unacked.remove(seq);
    }
  }

  void _handleReliable(int seq, Uint8List piece, (int, int, int)? frag) {
    _acks.record(seq);
    if (seqGreater(_expectedReliableSeq, seq)) return;
    if (_reliableHeld.containsKey(seq)) return;
    _reliableHeld[seq] = _encodeHeld(piece, frag);
    while (true) {
      final held = _reliableHeld.remove(_expectedReliableSeq);
      if (held == null) break;
      _expectedReliableSeq = seqNext(_expectedReliableSeq);
      _deliverHeld(Channel.reliable, held);
    }
  }

  // Held reliable pieces carry their fragment header so ordered delivery and
  // reassembly compose; a 1-byte tag distinguishes plain from fragmented.
  Uint8List _encodeHeld(Uint8List piece, (int, int, int)? frag) {
    final w = ByteWriter(piece.length + 6);
    if (frag == null) {
      w.writeU8(0);
    } else {
      w
        ..writeU8(1)
        ..writeU16(frag.$1)
        ..writeU8(frag.$2)
        ..writeU8(frag.$3);
    }
    w.writeBytes(piece);
    return w.toBytes();
  }

  void _deliverHeld(Channel channel, Uint8List held) {
    final r = ByteReader(held);
    if (r.readU8() == 0) {
      _emit(channel, Uint8List.fromList(r.readBytes(r.remaining)));
      return;
    }
    final frag = (r.readU16(), r.readU8(), r.readU8());
    _reassemble(channel, frag, Uint8List.fromList(r.readBytes(r.remaining)));
  }

  void _handleUnreliable(int seq, Uint8List piece, (int, int, int)? frag) {
    if (frag == null) {
      if (_anyUnreliable && !seqGreater(seq, _latestUnreliableSeq)) return;
      _anyUnreliable = true;
      _latestUnreliableSeq = seq;
      _emit(Channel.unreliable, piece);
      return;
    }
    // Fragmented unreliable payloads skip newest-wins sequencing; the
    // reassembler's timeout discards incomplete ones.
    _reassemble(Channel.unreliable, frag, piece);
  }

  void _reassemble(Channel channel, (int, int, int) frag, Uint8List piece) {
    final (id, index, count) = frag;
    if (index >= count || count == 0) return;
    final entry = _reassembly.putIfAbsent(
      id,
      () => _Reassembly(count)..createdMicros = _now(),
    );
    if (entry.count != count || entry.parts[index] != null) return;
    entry.parts[index] = piece;
    entry.received++;
    if (entry.received < count) return;
    _reassembly.remove(id);
    final total = entry.parts.fold<int>(0, (n, p) => n + p!.length);
    final whole = Uint8List(total);
    var offset = 0;
    for (final part in entry.parts) {
      whole.setRange(offset, offset + part!.length, part);
      offset += part.length;
    }
    _emit(channel, whole);
  }

  void _emit(Channel channel, Uint8List payload) {
    if (!_messages.isClosed) _messages.add(NetMessage(channel, payload));
  }

  void _housekeep() {
    final now = _now();
    if (now - _lastReceivedMicros > config.timeout.inMicroseconds) {
      _fail();
      return;
    }
    final resendAfter = config.resendInterval.inMicroseconds;
    for (final out in _unacked.values) {
      if (now - out.lastSentMicros >= resendAfter) {
        out.lastSentMicros = now;
        _transmit(out.datagram);
      }
    }
    if (now - _lastSentMicros >= config.keepaliveInterval.inMicroseconds) {
      final w = ByteWriter(16)
        ..writeU8(magicByte)
        ..writeU8(PacketKind.keepalive)
        ..writeU32(sessionId);
      _writeAcks(w);
      _transmit(w.toBytes());
    }
    final staleBefore = now - 2 * config.timeout.inMicroseconds;
    _reassembly.removeWhere((_, r) => r.createdMicros < staleBefore);
  }

  void _fail() {
    if (!_open) return;
    _open = false;
    _timer?.cancel();
    if (!_messages.isClosed) _messages.close();
    if (!_done.isCompleted) _done.complete();
    _onClosed?.call(this);
  }

  @override
  Future<void> close() async {
    if (!_open) return;
    final w = ByteWriter(8)
      ..writeU8(magicByte)
      ..writeU8(PacketKind.disconnect)
      ..writeU32(sessionId);
    for (var i = 0; i < 3; i++) {
      _sendDatagram(w.toBytes());
    }
    _fail();
  }
}
