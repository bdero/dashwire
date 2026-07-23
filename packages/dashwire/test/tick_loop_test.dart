import 'package:dashwire/dashwire.dart';
import 'package:test/test.dart';

void main() {
  test('accumulates fractional frames into fixed ticks', () {
    final loop = TickLoop(tickRate: 10);
    final ticks = <int>[];
    expect(loop.advance(0.05, ticks.add), 0);
    expect(loop.advance(0.05, ticks.add), 1);
    expect(loop.advance(0.25, ticks.add), 2);
    expect(ticks, [0, 1, 2]);
    expect(loop.tick, 3);
    expect(loop.alpha, closeTo(0.5, 1e-9));
  });

  test('total ticks track total elapsed time', () {
    final loop = TickLoop(tickRate: 60);
    var count = 0;
    var elapsed = 0.0;
    for (var i = 0; i < 1000; i++) {
      const frame = 1 / 143;
      elapsed += frame;
      count += loop.advance(frame, (_) {});
    }
    expect(count, (elapsed * 60).floor());
  });

  test('spiral guard drops excess time', () {
    final loop = TickLoop(tickRate: 60, maxCatchUpTicks: 4);
    expect(loop.advance(10, (_) {}), 4);
    expect(loop.tick, 4);
    expect(loop.alpha, lessThan(1));
  });

  test('seek jumps the timeline', () {
    final loop = TickLoop(tickRate: 60)..seek(100);
    final ticks = <int>[];
    loop.advance(1 / 60, ticks.add);
    expect(ticks, [100]);
  });
}
