import 'dart:math';

/// Per-connection outbound byte allowance, refilled once per tick.
///
/// Unspent allowance carries over up to [maxCarryTicks] ticks of burst so a
/// quiet connection can absorb a spike without exceeding its average rate.
final class ByteBudget {
  ByteBudget({required this.bytesPerTick, this.maxCarryTicks = 2})
    : assert(bytesPerTick > 0),
      assert(maxCarryTicks >= 1),
      _available = bytesPerTick;

  final int bytesPerTick;
  final int maxCarryTicks;
  int _available;

  int get available => _available;

  /// Call once per tick before packing.
  void refill() {
    _available = min(_available + bytesPerTick, bytesPerTick * maxCarryTicks);
  }

  /// Spends [bytes] if the budget allows, returning whether it did.
  bool trySpend(int bytes) {
    if (bytes > _available) return false;
    _available -= bytes;
    return true;
  }
}
