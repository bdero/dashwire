import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'transport.dart';

/// Network conditions injected by [SimulatorConnection].
final class SimulatedConditions {
  const SimulatedConditions({
    this.latency = Duration.zero,
    this.jitter = Duration.zero,
    this.unreliableLoss = 0,
    this.unreliableDuplicate = 0,
    this.seed = 0,
  }) : assert(unreliableLoss >= 0 && unreliableLoss < 1),
       assert(unreliableDuplicate >= 0 && unreliableDuplicate < 1);

  /// One-way delivery delay. Wrapping one end of a pair yields a round trip
  /// of twice this.
  final Duration latency;

  /// Uniform random delay added per delivery, in [0, jitter].
  final Duration jitter;

  /// Drop probability per unreliable payload, applied per direction.
  final double unreliableLoss;

  /// Duplicate probability per unreliable payload.
  final double unreliableDuplicate;

  /// Seed for the deterministic random stream.
  final int seed;
}

/// Wraps a [WireConnection] and degrades it.
///
/// Outbound sends and inbound deliveries are delayed by latency plus jitter;
/// unreliable payloads are additionally dropped or duplicated. Reliable
/// payloads are never lost and their ordering is preserved (delivery times
/// are clamped monotonic), matching what a real reliable channel guarantees.
final class SimulatorConnection implements WireConnection {
  SimulatorConnection(this._inner, this.conditions)
    : _random = Random(conditions.seed) {
    _sub = _inner.messages.listen(
      (message) => _schedule(message.channel, () {
        if (!_messages.isClosed) _messages.add(message);
      }),
      onDone: _drainThenClose,
    );
    _inner.done.whenComplete(() {});
  }

  final WireConnection _inner;
  final SimulatedConditions conditions;
  final Random _random;
  final _messages = StreamController<NetMessage>();
  late final StreamSubscription<NetMessage> _sub;
  int _pending = 0;
  bool _inboundDone = false;
  final _done = Completer<void>();
  int _lastReliableOutMicros = 0;
  int _lastReliableInMicros = 0;
  final _epoch = Stopwatch()..start();

  @override
  bool get isOpen => _inner.isOpen;

  @override
  Stream<NetMessage> get messages => _messages.stream;

  @override
  Future<void> get done => _done.future;

  int _delayMicros() {
    final jitter = conditions.jitter.inMicroseconds;
    return conditions.latency.inMicroseconds +
        (jitter == 0 ? 0 : _random.nextInt(jitter + 1));
  }

  /// Runs [deliver] after the simulated delay, at most once per call.
  ///
  /// Reliable deliveries are clamped so they never overtake an earlier
  /// reliable delivery in the same direction. [outbound] picks which
  /// direction's clamp to use.
  void _schedule(
    Channel channel,
    void Function() deliver, {
    bool outbound = false,
  }) {
    if (channel == Channel.unreliable) {
      if (_random.nextDouble() < conditions.unreliableLoss) return;
      if (_random.nextDouble() < conditions.unreliableDuplicate) {
        _schedule(Channel.unreliable, deliver, outbound: outbound);
      }
    }
    var at = _epoch.elapsedMicroseconds + _delayMicros();
    if (channel == Channel.reliable) {
      if (outbound) {
        at = _lastReliableOutMicros = max(at, _lastReliableOutMicros);
      } else {
        at = _lastReliableInMicros = max(at, _lastReliableInMicros);
      }
    }
    _pending++;
    Timer(Duration(microseconds: at - _epoch.elapsedMicroseconds), () {
      _pending--;
      deliver();
      if (_inboundDone && _pending == 0) _drainThenClose();
    });
  }

  @override
  void send(Channel channel, Uint8List payload) {
    if (!_inner.isOpen) throw StateError('send on a closed connection');
    final copy = Uint8List.fromList(payload);
    _schedule(channel, () {
      if (_inner.isOpen) _inner.send(channel, copy);
    }, outbound: true);
  }

  void _drainThenClose() {
    _inboundDone = true;
    if (_pending > 0) return;
    if (!_messages.isClosed) _messages.close();
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> close() async {
    await _inner.close();
    await _sub.cancel();
    _drainThenClose();
  }
}
