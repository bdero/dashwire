import 'dart:collection';

/// Interpolates between two recorded values at fraction [t] in `[0, 1]`.
typedef Interpolate<V> = V Function(V a, V b, double t);

/// Server-side per-tick history for lag-compensated rewind.
///
/// Records each tracked entity's value once per fixed tick, then rewinds a
/// set of entities to the (possibly fractional) tick a client actually
/// rendered, so hit detection runs against the world that client saw. The
/// rewind is clamped to [maxRewindTicks] so a high-latency client cannot
/// rewind arbitrarily far and disadvantage low-latency ones.
///
/// Keyed on the tick the CLIENT reports rendering, never a ping estimate, so
/// jitter and interpolated proxies do not skew the result.
final class LagCompensation<K, V> {
  LagCompensation({
    required this.interpolate,
    this.capacityTicks = 32,
    this.maxRewindTicks = 20,
  });

  final Interpolate<V> interpolate;

  /// Ticks of history retained per entity.
  final int capacityTicks;

  /// Furthest a rewind may reach behind the newest recorded tick.
  final int maxRewindTicks;

  final Map<K, SplayTreeMap<int, V>> _history = {};
  int _newestTick = -1;

  int get newestTick => _newestTick;

  /// Records [key]'s [value] at [tick]. Call once per key per fixed tick.
  void record(int tick, K key, V value) {
    if (tick > _newestTick) _newestTick = tick;
    final samples = _history.putIfAbsent(key, SplayTreeMap.new);
    samples[tick] = value;
    final cutoff = _newestTick - capacityTicks;
    while (samples.isNotEmpty && samples.firstKey()! < cutoff) {
      samples.remove(samples.firstKey());
    }
  }

  /// Records a whole tick of entity values at once.
  void recordAll(int tick, Map<K, V> values) {
    values.forEach((key, value) => record(tick, key, value));
  }

  /// Drops all history for [key] (a despawn).
  void forget(K key) => _history.remove(key);

  /// The value of [key] as it was at [tick], interpolating between the
  /// bracketing recorded ticks, clamped to the rewind cap. Null if the key
  /// was never recorded.
  V? rewind(K key, double tick) {
    final samples = _history[key];
    if (samples == null || samples.isEmpty) return null;

    final floor = (_newestTick - maxRewindTicks).toDouble();
    final capped = tick.clamp(floor, _newestTick.toDouble());

    final lowTick = capped.floor();
    final highTick = capped.ceil();
    final low = _sampleAtOrBefore(samples, lowTick);
    final high = _sampleAtOrAfter(samples, highTick);
    if (low == null) return high?.$2 ?? samples[samples.firstKey()];
    if (high == null) return low.$2;
    if (low.$1 == high.$1) return low.$2;
    final frac = (capped - low.$1) / (high.$1 - low.$1);
    return interpolate(low.$2, high.$2, frac.clamp(0, 1));
  }

  /// Rewinds every key in [keys] (typically the shooter's relevancy set).
  Map<K, V> rewindAll(Iterable<K> keys, double tick) {
    final out = <K, V>{};
    for (final key in keys) {
      final value = rewind(key, tick);
      if (value != null) out[key] = value;
    }
    return out;
  }

  (int, V)? _sampleAtOrBefore(SplayTreeMap<int, V> samples, int tick) {
    final key = samples.lastKeyBefore(tick + 1) ?? samples.firstKeyAfter(tick);
    return key == null ? null : (key, samples[key] as V);
  }

  (int, V)? _sampleAtOrAfter(SplayTreeMap<int, V> samples, int tick) {
    final key = samples.firstKeyAfter(tick - 1) ?? samples.lastKeyBefore(tick);
    return key == null ? null : (key, samples[key] as V);
  }
}
