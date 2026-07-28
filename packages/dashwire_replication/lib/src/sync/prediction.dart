/// Deterministic per-tick simulation step, shared by the server and the
/// predicting client so the two agree. Advances [state] by one fixed [dt]
/// under [input].
typedef SimulateStep<I, S> = S Function(S state, I input, double dt);

/// Whether a predicted state has diverged from the authoritative one enough
/// to warrant a correction.
typedef Divergence<S> = bool Function(S predicted, S authoritative);

/// Client-side prediction with authoritative input-replay reconciliation.
///
/// The client advances the predicted state one fixed tick at a time from its
/// own input ([advance]), keeping a ring of `(tick, input, state)`. When the
/// server confirms the authoritative state after a given input tick
/// ([reconcile]), the predictor adopts that state and replays the inputs the
/// server has not yet applied, so local input stays instant while the sim
/// stays server-authoritative. Only this predicted state needs the [step] to
/// be deterministic, not the whole game.
///
/// Generic over the input type [I] and state type [S]; the engine layer binds
/// them to concrete input structs and poses.
final class Predictor<I, S> {
  Predictor({
    required this.step,
    required this.dt,
    required this.diverged,
    this.historyLength = 256,
  });

  final SimulateStep<I, S> step;

  /// Fixed timestep, seconds per tick.
  final double dt;

  final Divergence<S> diverged;

  /// Most `(tick, input, state)` entries retained for replay.
  final int historyLength;

  final List<(int, I, S)> _history = [];
  late S _current;
  int _currentTick = 0;
  bool _seeded = false;

  /// The latest predicted state. Reading before [reset] throws.
  S get current {
    if (!_seeded) throw StateError('predictor used before reset');
    return _current;
  }

  /// The tick of [current].
  int get currentTick => _currentTick;

  bool get isSeeded => _seeded;

  /// Ticks predicted ahead of the last reconciled/authoritative tick.
  int get pendingTicks => _history.length;

  /// Seeds the predictor with an authoritative [state] at [tick]. Clears any
  /// prediction history.
  void reset(int tick, S state) {
    _current = state;
    _currentTick = tick;
    _history.clear();
    _seeded = true;
  }

  /// Advances one predicted tick from [input] and returns the new state.
  S advance(int tick, I input) {
    _current = step(_current, input, dt);
    _currentTick = tick;
    _history.add((tick, input, _current));
    while (_history.length > historyLength) {
      _history.removeAt(0);
    }
    return _current;
  }

  /// Reconciles against the authoritative [state], which is the result of the
  /// peer's input through [ackedTick].
  ///
  /// Drops acknowledged history, and if the prediction for [ackedTick]
  /// diverged, adopts [state] and replays every input after [ackedTick].
  /// Returns true when a correction was applied.
  bool reconcile(int ackedTick, S state) {
    if (!_seeded) {
      reset(ackedTick, state);
      return true;
    }

    // Inputs the server has not confirmed yet, to replay on top of authority.
    final pending = <(int, I, S)>[
      for (final entry in _history)
        if (entry.$1 > ackedTick) entry,
    ];

    final predictedAt = _predictedStateAt(ackedTick);
    // Nothing to compare against, or the acked tick predates our buffer, and
    // we still hold newer predictions: keep predicting, adopting authority
    // would rubber-band backward.
    if (predictedAt == null && pending.isNotEmpty) {
      _retain(pending);
      return false;
    }

    final matched = predictedAt != null && !diverged(predictedAt, state);
    if (matched) {
      _retain(pending);
      return false;
    }

    // Correct: rebuild the pending tail on top of the authoritative state.
    var s = state;
    final rebuilt = <(int, I, S)>[];
    for (final (tick, input, _) in pending) {
      s = step(s, input, dt);
      rebuilt.add((tick, input, s));
    }
    _history
      ..clear()
      ..addAll(rebuilt);
    _current = rebuilt.isEmpty ? state : rebuilt.last.$3;
    _currentTick = rebuilt.isEmpty ? ackedTick : rebuilt.last.$1;
    return true;
  }

  void _retain(List<(int, I, S)> pending) {
    _history
      ..clear()
      ..addAll(pending);
    if (pending.isNotEmpty) {
      _current = pending.last.$3;
      _currentTick = pending.last.$1;
    }
  }

  S? _predictedStateAt(int tick) {
    for (final (t, _, s) in _history) {
      if (t == tick) return s;
    }
    return null;
  }
}
