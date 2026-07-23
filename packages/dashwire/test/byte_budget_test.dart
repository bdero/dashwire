import 'package:dashwire/dashwire.dart';
import 'package:test/test.dart';

void main() {
  test('spends within the allowance and refuses past it', () {
    final budget = ByteBudget(bytesPerTick: 100);
    expect(budget.trySpend(60), isTrue);
    expect(budget.trySpend(60), isFalse);
    expect(budget.trySpend(40), isTrue);
    expect(budget.available, 0);
  });

  test('carry-over is capped at the burst ceiling', () {
    final budget = ByteBudget(bytesPerTick: 100, maxCarryTicks: 2);
    budget.refill();
    budget.refill();
    budget.refill();
    expect(budget.available, 200);
  });
}
