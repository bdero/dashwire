import 'dart:collection';
import 'dart:typed_data';

import 'package:dashwire/dashwire.dart';

import 'messages.dart';

/// Encodes an [MessageKind.inputCommand] body from [commands] (ticks
/// ascending). Pure so the wire format is golden-testable.
Uint8List encodeInputCommand(List<(int, Uint8List)> commands) {
  final w = ByteWriter(64)
    ..writeU8(MessageKind.inputCommand)
    ..writeVarUint(commands.length);
  for (final (tick, payload) in commands) {
    w
      ..writeVarUint(tick)
      ..writeLengthPrefixedBytes(payload);
  }
  return w.toBytes();
}

/// Client-side outgoing input command buffer.
///
/// Tags each input with the server tick it is for, keeps a short tail of
/// recent commands so a dropped unreliable packet self-heals from a later
/// one, and adapts its send-ahead lead from the server's buffer-depth
/// feedback so the server's per-connection input buffer stays near
/// [targetDepth].
final class ClientInputSender {
  ClientInputSender(
    this._session, {
    this.redundancy = 8,
    this.targetDepth = 2,
    this.minLead = 1,
    this.maxLead = 8,
    NowMicros now = defaultNowMicros,
  }) : _now = now,
       _lead = minLead;

  final Session _session;
  final int redundancy;
  final int targetDepth;
  final int minLead;
  final int maxLead;
  final NowMicros _now;

  final List<(int, Uint8List)> _recent = [];
  int _lastAppliedTick = 0;
  int _reportedDepth = 0;
  int _lead;

  int get lastAppliedTick => _lastAppliedTick;
  int get bufferDepth => _reportedDepth;
  int get leadTicks => _lead;

  /// The tick the next input should target, one-way latency plus the adaptive
  /// lead ahead of the server.
  int nextTick() =>
      _session.clock.inputTickAt(_now(), marginTicks: _lead.toDouble());

  /// Buffers an input for [tick] and transmits the recent tail.
  void send(int tick, Uint8List payload) {
    _recent
      ..removeWhere((e) => e.$1 == tick)
      ..add((tick, Uint8List.fromList(payload)));
    _recent.sort((a, b) => a.$1.compareTo(b.$1));
    while (_recent.length > redundancy) {
      _recent.removeAt(0);
    }
    _session.sendApp(Channel.unreliable, encodeInputCommand(_recent));
  }

  /// Applies a server input ack (already past the kind byte).
  void handleAck(ByteReader r) {
    final applied = r.readVarUint();
    final depth = r.readVarUint();
    if (applied > _lastAppliedTick) _lastAppliedTick = applied;
    _reportedDepth = depth;
    // Proportional-ish lead control toward targetDepth, one tick per ack.
    if (depth < targetDepth) {
      _lead = (_lead + 1).clamp(minLead, maxLead);
    } else if (depth > targetDepth + 1) {
      _lead = (_lead - 1).clamp(minLead, maxLead);
    }
    _recent.removeWhere((e) => e.$1 <= _lastAppliedTick);
  }
}

/// Server-side per-connection input buffer.
///
/// Ingests redundant input commands, hands the game the input to apply at a
/// tick ([consume]), and reports progress plus buffer depth for the client's
/// pacing. A missing tick re-uses the last applied input (hold-last) so the
/// simulation never stalls on a dropped packet.
final class ServerInputBuffer {
  ServerInputBuffer({this.window = 64});

  /// Most buffered future ticks kept before the oldest is dropped.
  final int window;

  final SplayTreeMap<int, Uint8List> _buffered = SplayTreeMap();
  int _lastAppliedTick = 0;
  Uint8List? _lastApplied;
  bool _active = false;

  /// Whether the most recent [consume] had to hold the previous input.
  bool starvedLast = false;

  /// Whether this connection has sent any input command.
  bool get isActive => _active;

  int get lastAppliedTick => _lastAppliedTick;

  /// Buffered commands strictly ahead of the last applied tick.
  int get depth => _buffered.length;

  /// Ingests an input command message (already past the kind byte).
  void ingest(ByteReader r) {
    _active = true;
    final count = r.readVarUint();
    for (var i = 0; i < count; i++) {
      final tick = r.readVarUint();
      final payload = Uint8List.fromList(r.readLengthPrefixedBytes());
      if (tick <= _lastAppliedTick) continue;
      _buffered[tick] = payload;
    }
    while (_buffered.length > window) {
      _buffered.remove(_buffered.firstKey());
    }
  }

  /// Returns the input to apply at [tick], the exact command if buffered,
  /// else the last applied input re-used (with [starvedLast] set). Prunes
  /// consumed history.
  Uint8List? consume(int tick) {
    final exact = _buffered.remove(tick);
    if (exact != null) {
      _lastAppliedTick = tick;
      _lastApplied = exact;
      starvedLast = false;
      while (_buffered.isNotEmpty && _buffered.firstKey()! <= tick) {
        _buffered.remove(_buffered.firstKey());
      }
      return exact;
    }
    starvedLast = _active;
    return _lastApplied;
  }

  /// Writes an [MessageKind.inputAck] for this connection.
  void writeAck(ByteWriter w) {
    w
      ..writeU8(MessageKind.inputAck)
      ..writeVarUint(_lastAppliedTick)
      ..writeVarUint(_buffered.length);
  }
}
