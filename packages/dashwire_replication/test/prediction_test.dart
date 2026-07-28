import 'package:dashwire_replication/dashwire_replication.dart';
import 'package:test/test.dart';

// A 1D constant-velocity sim: input is velocity, state is position.
Predictor<double, double> _predictor({double dt = 1}) =>
    Predictor<double, double>(
      step: (position, velocity, dt) => position + velocity * dt,
      dt: dt,
      diverged: (a, b) => (a - b).abs() > 1e-9,
    );

void main() {
  test('advance integrates input and records history', () {
    final p = _predictor()..reset(0, 0);
    expect(p.advance(1, 2), 2);
    expect(p.advance(2, 2), 4);
    expect(p.advance(3, 2), 6);
    expect(p.current, 6);
    expect(p.currentTick, 3);
    expect(p.pendingTicks, 3);
  });

  test('a matching authoritative state applies no correction', () {
    final p = _predictor()..reset(0, 0);
    p
      ..advance(1, 2)
      ..advance(2, 2)
      ..advance(3, 2);
    // Server confirms tick 1 = position 2, exactly what we predicted.
    final corrected = p.reconcile(1, 2);
    expect(corrected, isFalse);
    expect(p.current, 6); // unchanged
    expect(p.pendingTicks, 2); // ticks 2 and 3 still pending
  });

  test('a diverged authoritative state rolls back and replays', () {
    final p = _predictor()..reset(0, 0);
    p
      ..advance(1, 2) // predicted 2
      ..advance(2, 2) // predicted 4
      ..advance(3, 2); // predicted 6
    // Server says tick 1 was actually position 5 (we mispredicted, e.g. a
    // collision the client did not see). Replaying inputs for ticks 2 and 3
    // (velocity 2 each) yields 5 + 2 + 2 = 9.
    final corrected = p.reconcile(1, 5);
    expect(corrected, isTrue);
    expect(p.current, 9);
    expect(p.currentTick, 3);
    expect(p.pendingTicks, 2);
  });

  test('reconciling the newest tick clears the pending tail', () {
    final p = _predictor()..reset(0, 0);
    p
      ..advance(1, 2)
      ..advance(2, 2);
    final corrected = p.reconcile(2, 10); // authority for the newest tick
    expect(corrected, isTrue);
    expect(p.current, 10);
    expect(p.pendingTicks, 0);
  });

  test('a stale ack older than the buffer keeps the prediction', () {
    final p = _predictor()..reset(10, 100);
    p
      ..advance(11, 1)
      ..advance(12, 1);
    // Ack for tick 5 predates our history; adopting it would rubber-band.
    final corrected = p.reconcile(5, 50);
    expect(corrected, isFalse);
    expect(p.current, 102);
  });

  test('first reconcile before any prediction seeds the state', () {
    final p = _predictor();
    expect(p.isSeeded, isFalse);
    final corrected = p.reconcile(7, 42);
    expect(corrected, isTrue);
    expect(p.current, 42);
    expect(p.currentTick, 7);
  });

  test('history is bounded', () {
    final p = Predictor<double, double>(
      step: (s, i, dt) => s + i,
      dt: 1,
      diverged: (a, b) => a != b,
      historyLength: 4,
    )..reset(0, 0);
    for (var t = 1; t <= 20; t++) {
      p.advance(t, 1);
    }
    expect(p.pendingTicks, 4);
    expect(p.current, 20);
  });
}
