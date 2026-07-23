import '../net_id.dart';

/// Contributes ids to a peer's relevant set each tick.
abstract interface class RelevancyFilter {
  void collect(int peerId, void Function(NetId) add);
}

/// Grid-bucketed spatial relevancy in 2D.
///
/// Register object positions and per-peer views; objects within a view's
/// radius (conservatively, by cell) are relevant to that peer. 3D worlds
/// usually cull on their ground plane, which this covers.
final class SpatialGridFilter implements RelevancyFilter {
  SpatialGridFilter({this.cellSize = 32});

  final double cellSize;
  final Map<NetId, (double, double)> _positions = {};
  final Map<(int, int), Set<NetId>> _cells = {};
  final Map<int, (double, double, double)> _views = {};

  (int, int) _cellOf(double x, double y) =>
      ((x / cellSize).floor(), (y / cellSize).floor());

  void setPosition(NetId id, double x, double y) {
    remove(id);
    _positions[id] = (x, y);
    _cells.putIfAbsent(_cellOf(x, y), () => {}).add(id);
  }

  void remove(NetId id) {
    final previous = _positions.remove(id);
    if (previous == null) return;
    final cell = _cellOf(previous.$1, previous.$2);
    final bucket = _cells[cell];
    bucket?.remove(id);
    if (bucket != null && bucket.isEmpty) _cells.remove(cell);
  }

  /// Sets what [peerId] can see.
  void setView(int peerId, double x, double y, double radius) =>
      _views[peerId] = (x, y, radius);

  void removeView(int peerId) => _views.remove(peerId);

  @override
  void collect(int peerId, void Function(NetId) add) {
    final view = _views[peerId];
    if (view == null) return;
    final (x, y, radius) = view;
    final (minX, minY) = _cellOf(x - radius, y - radius);
    final (maxX, maxY) = _cellOf(x + radius, y + radius);
    for (var cx = minX; cx <= maxX; cx++) {
      for (var cy = minY; cy <= maxY; cy++) {
        final bucket = _cells[(cx, cy)];
        if (bucket == null) continue;
        bucket.forEach(add);
      }
    }
  }
}
