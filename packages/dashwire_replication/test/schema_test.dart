import 'dart:math';

import 'package:dashwire/dashwire.dart';
import 'package:dashwire_replication/dashwire_replication.dart';
import 'package:test/test.dart';

import 'test_replicas.dart';

void main() {
  group('codecs', () {
    test(
      'quantized float encodes to golden bytes and compares at precision',
      () {
        final codec = Codecs.quantized(0.1);
        final w = ByteWriter();
        codec.encode(w, 1.23);
        // round(1.23/0.1)=12, zigzag 24.
        expect(w.toBytes(), [24]);
        expect(codec.equals(1.23, 1.21), isTrue);
        expect(codec.equals(1.23, 1.31), isFalse);
        final r = ByteReader(w.toBytes());
        expect(codec.decode(r), closeTo(1.2, 1e-9));
      },
    );

    test('codec ids print identically on every compiler', () {
      // Regression: ids embedded resolutions via toString, which renders
      // 1.0 as "1.0" on the VM and "1" under dart2js, so a native host and
      // a web client computed different schema hashes. The chrome suite
      // runs this same expectation to pin the web side.
      expect(Codecs.quantized(1).id, 'q(1e+0)');
      expect(Codecs.quantized(0.001).id, 'q(1e-3)');
      expect(Codecs.vec3(0.25).id, 'v3(2.5e-1)');
    });

    test('vec3 round trips at resolution', () {
      final codec = Codecs.vec3(0.01);
      final w = ByteWriter();
      codec.encode(w, (1.234, -5.678, 0.0));
      final v = codec.decode(ByteReader(w.toBytes()));
      expect(v.$1, closeTo(1.23, 0.006));
      expect(v.$2, closeTo(-5.68, 0.006));
      expect(v.$3, 0);
    });

    test('smallest-three quaternion stays within tolerance', () {
      final random = Random(5);
      for (var i = 0; i < 200; i++) {
        // Random unit quaternion.
        var (x, y, z, w) = (
          random.nextDouble() * 2 - 1,
          random.nextDouble() * 2 - 1,
          random.nextDouble() * 2 - 1,
          random.nextDouble() * 2 - 1,
        );
        final norm = sqrt(x * x + y * y + z * z + w * w);
        if (norm < 1e-6) continue;
        (x, y, z, w) = (x / norm, y / norm, z / norm, w / norm);

        final writer = ByteWriter();
        Codecs.quat.encode(writer, (x, y, z, w));
        expect(writer.length, 4);
        final q = Codecs.quat.decode(ByteReader(writer.toBytes()));
        // q and -q are the same rotation; compare against the closer sign.
        final dot = q.$1 * x + q.$2 * y + q.$3 * z + q.$4 * w;
        final sign = dot < 0 ? -1.0 : 1.0;
        expect(q.$1 * sign, closeTo(x, 0.005));
        expect(q.$2 * sign, closeTo(y, 0.005));
        expect(q.$3 * sign, closeTo(z, 0.005));
        expect(q.$4 * sign, closeTo(w, 0.005));
      }
    });
  });

  group('replica schema', () {
    test('fields register in declaration order', () {
      final player = PlayerReplica();
      expect(player.fields.map((f) => f.name), [
        'kind',
        'name',
        'score',
        'position',
        'secret',
        'aim',
      ]);
      expect(player.position.index, 3);
    });

    test('writes at wire precision do not dirty', () {
      final player = PlayerReplica();
      final before = player.version;
      player.position.value = (0.001, 0.0, 0.0); // Below 0.01 resolution.
      expect(player.version, before);
      player.position.value = (0.5, 0.0, 0.0);
      expect(player.version, greaterThan(before));
    });

    test('onChanged fires with previous and next', () {
      final player = PlayerReplica();
      final calls = <(int, int)>[];
      player.score.onChanged((previous, next) => calls.add((previous, next)));
      player.score.value = 7;
      player.score.value = 7;
      player.score.value = 9;
      expect(calls, [(0, 7), (7, 9)]);
    });

    test('a replica supports at most 32 fields', () {
      expect(_ManyFields.new, throwsStateError);
    });
  });

  group('schema hash', () {
    test('is stable and registration-order independent', () {
      final a = ReplicaRegistry()
        ..register(PlayerReplica.new)
        ..register(DotReplica.new);
      final b = ReplicaRegistry()
        ..register(DotReplica.new)
        ..register(PlayerReplica.new);
      expect(a.schemaHash, b.schemaHash);
    });

    test('changes when a type is added', () {
      final a = ReplicaRegistry()..register(PlayerReplica.new);
      final b = ReplicaRegistry()
        ..register(PlayerReplica.new)
        ..register(DotReplica.new);
      expect(a.schemaHash, isNot(b.schemaHash));
    });

    test('changes when a codec changes', () {
      final a = ReplicaRegistry()..register(DotReplica.new);
      final b = ReplicaRegistry()..register(_CoarseDot.new);
      expect(a.schemaHash, isNot(b.schemaHash));
    });
  });
}

final class _ManyFields extends Replica {
  _ManyFields() {
    for (var i = 0; i < 33; i++) {
      rep('f$i', 0, codec: Codecs.varUint);
    }
  }

  @override
  String get typeKey => 'many';
}

final class _CoarseDot extends Replica {
  _CoarseDot() {
    position = rep('position', (0.0, 0.0, 0.0), codec: Codecs.vec3(0.1));
  }

  @override
  String get typeKey => 'dot';

  late final Rep<Vec3> position;
}
