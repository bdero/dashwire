import 'package:dashwire_replication/dashwire_replication.dart';
import 'package:test/test.dart';

final class _Pawn extends TransformReplica {
  _Pawn() {
    speed = rep('speed', 0.0, codec: Codecs.quantized(0.1));
  }

  @override
  String get typeKey => 'pawn';

  late final Rep<double> speed;
}

void main() {
  test('base pose fields register before subclass fields', () {
    final pawn = _Pawn();
    expect(pawn.fields.map((f) => f.name), ['position', 'rotation', 'speed']);
    pawn.position.value = (1.0, 2.0, 3.0);
    expect(pawn.rotation.value, (0.0, 0.0, 0.0, 1.0));
  });
}
