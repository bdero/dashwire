/// Fixed-timestep accumulator.
///
/// Pure and externally driven, the caller measures elapsed wall time and
/// calls [advance]; the loop converts it into zero or more fixed ticks.
final class TickLoop {
  TickLoop({required this.tickRate, this.maxCatchUpTicks = 8})
    : assert(tickRate > 0),
      secondsPerTick = 1 / tickRate;

  /// Simulation ticks per second.
  final int tickRate;

  final double secondsPerTick;

  /// Ceiling on ticks run in one [advance], the spiral-of-death guard.
  /// Excess accumulated time is dropped.
  final int maxCatchUpTicks;

  int _tick = 0;
  double _accumulator = 0;

  /// The next tick [advance] will run.
  int get tick => _tick;

  /// Fraction of the next tick already accumulated, in [0, 1). Use to
  /// interpolate rendering between tick states.
  double get alpha => _accumulator / secondsPerTick;

  /// Feeds [elapsedSeconds] of wall time, running [onTick] once per fixed
  /// tick. Returns the number of ticks run.
  int advance(double elapsedSeconds, void Function(int tick) onTick) {
    assert(elapsedSeconds >= 0);
    _accumulator += elapsedSeconds;
    final cap = maxCatchUpTicks * secondsPerTick;
    if (_accumulator > cap) _accumulator = cap;
    var ran = 0;
    while (_accumulator >= secondsPerTick) {
      _accumulator -= secondsPerTick;
      onTick(_tick++);
      ran++;
    }
    return ran;
  }

  /// Jumps the tick counter without running ticks, for joining an
  /// authoritative timeline mid-stream.
  void seek(int tick) {
    _tick = tick;
    _accumulator = 0;
  }
}
