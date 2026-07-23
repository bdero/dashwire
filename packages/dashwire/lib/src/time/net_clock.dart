/// Monotonic microsecond clock used across the session layer.
///
/// A function type so tests can supply fake time.
typedef NowMicros = int Function();

final _stopwatch = Stopwatch()..start();

/// Default monotonic clock, microseconds since process start.
int defaultNowMicros() => _stopwatch.elapsedMicroseconds;

class _Sample {
  _Sample(
    this.rttMicros,
    this.offsetMicros,
    this.serverTick,
    this.serverMicros,
  );

  final int rttMicros;
  final int offsetMicros;
  final int serverTick;
  final int serverMicros;
}

/// Estimates the server clock and tick timeline from ping/pong samples.
///
/// Each pong yields an offset estimate (server time minus local time,
/// assuming symmetric latency). The estimate from the lowest-RTT sample in a
/// sliding window wins, since low RTT bounds the asymmetry error.
final class NetClock {
  NetClock({required this.tickRate, this.sampleWindow = 8})
    : assert(tickRate > 0);

  /// Server simulation ticks per second.
  final int tickRate;
  final int sampleWindow;

  final List<_Sample> _samples = [];
  double _rttEwmaMicros = 0;

  bool get isSynchronized => _samples.isNotEmpty;

  /// Smoothed round-trip time in milliseconds.
  double get rttMillis => _rttEwmaMicros / 1000;

  /// Records one ping/pong exchange.
  ///
  /// [clientSendMicros] and [clientReceiveMicros] are local times around the
  /// exchange; [serverMicros] and [serverTick] are the server clock and tick
  /// at the moment it answered.
  void addSample({
    required int clientSendMicros,
    required int clientReceiveMicros,
    required int serverMicros,
    required int serverTick,
  }) {
    final rtt = clientReceiveMicros - clientSendMicros;
    final offset = serverMicros + rtt ~/ 2 - clientReceiveMicros;
    _samples.add(_Sample(rtt, offset, serverTick, serverMicros));
    if (_samples.length > sampleWindow) _samples.removeAt(0);
    _rttEwmaMicros = _rttEwmaMicros == 0
        ? rtt.toDouble()
        : _rttEwmaMicros * 0.9 + rtt * 0.1;
  }

  _Sample get _best =>
      _samples.reduce((a, b) => a.rttMicros <= b.rttMicros ? a : b);

  /// Estimated server clock at local time [localMicros].
  int serverMicrosAt(int localMicros) {
    assert(isSynchronized);
    return localMicros + _best.offsetMicros;
  }

  /// Estimated (fractional) server tick at local time [localMicros].
  double serverTicksAt(int localMicros) {
    assert(isSynchronized);
    final best = _best;
    final sinceSample = serverMicrosAt(localMicros) - best.serverMicros;
    return best.serverTick + sinceSample * tickRate / 1e6;
  }

  /// Tick a client should stamp on input sent now so it arrives before the
  /// server simulates that tick. One-way latency plus [marginTicks].
  int inputTickAt(int localMicros, {double marginTicks = 1.5}) {
    final oneWayTicks = (_rttEwmaMicros / 2) * tickRate / 1e6;
    return (serverTicksAt(localMicros) + oneWayTicks + marginTicks).ceil();
  }
}
