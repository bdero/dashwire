import 'package:dashwire_replication/dashwire_replication.dart';
import 'package:test/test.dart';

// 1D positions so the interpolation is easy to reason about.
LagCompensation<String, double> _comp({int maxRewindTicks = 20}) =>
    LagCompensation<String, double>(
      interpolate: (a, b, t) => a + (b - a) * t,
      maxRewindTicks: maxRewindTicks,
    );

void main() {
  test('rewinds to an exact recorded tick', () {
    final comp = _comp();
    for (var t = 0; t <= 10; t++) {
      comp.record(t, 'a', t.toDouble()); // position == tick
    }
    expect(comp.rewind('a', 4), 4);
    expect(comp.rewind('a', 7), 7);
  });

  test('interpolates between bracketing ticks', () {
    final comp = _comp();
    comp
      ..record(0, 'a', 0)
      ..record(2, 'a', 20); // no sample at tick 1
    expect(comp.rewind('a', 1), 10); // halfway
    expect(comp.rewind('a', 0.5), 5);
    expect(comp.rewind('a', 1.5), 15);
  });

  test('clamps the rewind to the cap', () {
    final comp = _comp(maxRewindTicks: 3);
    for (var t = 0; t <= 10; t++) {
      comp.record(t, 'a', t.toDouble());
    }
    // Newest is 10, cap is 3, so a request for tick 2 clamps to tick 7.
    expect(comp.rewind('a', 2), 7);
    expect(comp.rewind('a', 9), 9); // within the cap, exact
  });

  test('rewindAll rewinds a set of keys to the same tick', () {
    final comp = _comp();
    for (var t = 0; t <= 5; t++) {
      comp
        ..record(t, 'a', t.toDouble())
        ..record(t, 'b', t * 10.0);
    }
    final rewound = comp.rewindAll(['a', 'b'], 3);
    expect(rewound, {'a': 3.0, 'b': 30.0});
  });

  test('unknown and forgotten keys rewind to null', () {
    final comp = _comp();
    comp.record(1, 'a', 1);
    expect(comp.rewind('missing', 1), isNull);
    comp.forget('a');
    expect(comp.rewind('a', 1), isNull);
  });

  test('old samples beyond capacity are pruned', () {
    final comp = LagCompensation<String, double>(
      interpolate: (a, b, t) => a + (b - a) * t,
      capacityTicks: 4,
    );
    for (var t = 0; t <= 20; t++) {
      comp.record(t, 'a', t.toDouble());
    }
    // Only the last few ticks survive; a far-past request clamps to the
    // retained range, never crashing.
    expect(comp.rewind('a', 19), 19);
  });
}
