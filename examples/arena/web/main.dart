import 'dart:convert';
import 'dart:js_interop';

import 'package:arena_example/arena_shared.dart';
import 'package:dashwire/dashwire.dart';
import 'package:dashwire_replication/dashwire_replication.dart';
import 'package:web/web.dart' as web;

/// Canvas client. Joins through the lobby, drives the owned player with
/// WASD/arrows, and renders remote players ~100ms in the past through a
/// small interpolation buffer.
Future<void> main() async {
  final joinResponse = await web.window.fetch('/join'.toJS).toDart;
  final joinBody = (await joinResponse.text().toDart).toDart;
  final port = (jsonDecode(joinBody) as Map<String, Object?>)['port'] as int;

  final session = await connectSession(
    await connectWebSocket(Uri.parse('ws://${Uri.base.host}:$port')),
    schemaHash: arenaRegistry().schemaHash,
  );
  final buffers = <Replica, _PositionBuffer>{};
  final client = ReplicationClient(
    registry: arenaRegistry(),
    session: session,
    onSpawn: (replica) {
      if (replica is ArenaPlayer) {
        final buffer = buffers[replica] = _PositionBuffer()
          ..push(replica.position.value);
        replica.position.onChanged((_, next) => buffer.push(next));
      }
    },
    onDespawn: buffers.remove,
  );

  final canvas = web.document.getElementById('arena')! as web.HTMLCanvasElement;
  final context = canvas.getContext('2d')! as web.CanvasRenderingContext2D;

  final keys = <String>{};
  web.document.onkeydown = ((web.KeyboardEvent e) => keys.add(e.key)).toJS;
  web.document.onkeyup = ((web.KeyboardEvent e) => keys.remove(e.key)).toJS;

  late final void Function() frame;
  void scheduleFrame() =>
      web.window.requestAnimationFrame(((num _) => frame()).toJS);

  double axis(Set<String> keys, List<String> minus, List<String> plus) {
    var value = 0.0;
    if (minus.any(keys.contains)) value -= 1;
    if (plus.any(keys.contains)) value += 1;
    return value;
  }

  frame = () {
    final me = client.replicas.values
        .whereType<ArenaPlayer>()
        .where((p) => p.owner == client.localPeerId)
        .firstOrNull;
    me?.input.value = (
      axis(keys, ['a', 'ArrowLeft'], ['d', 'ArrowRight']),
      axis(keys, ['w', 'ArrowUp'], ['s', 'ArrowDown']),
      0.0,
    );
    client.flush();

    context
      ..fillStyle = '#101418'.toJS
      ..fillRect(0, 0, arenaWidth, arenaHeight);

    final renderAt =
        web.window.performance.now() / 1000 - 0.1; // 100ms interp delay.
    for (final replica in client.replicas.values) {
      if (replica is Pellet) {
        final (x, y, _) = replica.position.value;
        context
          ..fillStyle = '#f5d76e'.toJS
          ..beginPath()
          ..arc(x, y, pelletRadius, 0, 6.2832)
          ..fill();
      }
    }
    for (final replica in client.replicas.values) {
      if (replica is! ArenaPlayer) continue;
      final isMe = replica.owner == client.localPeerId;
      final (x, y, _) = isMe
          ? replica.position.value
          : buffers[replica]?.sample(renderAt) ?? replica.position.value;
      context
        ..fillStyle = 'hsl(${replica.hue.value * 360 ~/ 256} 70% 55%)'.toJS
        ..beginPath()
        ..arc(x, y, playerRadius, 0, 6.2832)
        ..fill();
      if (isMe) {
        context
          ..strokeStyle = '#ffffff'.toJS
          ..lineWidth = 2
          ..stroke();
      }
      context
        ..fillStyle = '#e8e8e8'.toJS
        ..font = '12px sans-serif'
        ..fillText(
          '${replica.name.value} (${replica.score.value})',
          x - 30,
          y - playerRadius - 6,
        );
    }
    context
      ..fillStyle = '#8a949e'.toJS
      ..fillText(
        'peer ${client.localPeerId}, '
        'rtt ${session.clock.rttMillis.toStringAsFixed(0)}ms, '
        '${client.replicas.length} replicas',
        8,
        16,
      );
    scheduleFrame();
  };

  frame();
}

/// Timestamped position samples for rendering remote players slightly in
/// the past, so packet-rate updates become smooth motion.
final class _PositionBuffer {
  final List<(double, Vec3)> _samples = [];

  void push(Vec3 position) {
    _samples.add((web.window.performance.now() / 1000, position));
    while (_samples.length > 32) {
      _samples.removeAt(0);
    }
  }

  Vec3 sample(double at) {
    if (_samples.isEmpty) return (0, 0, 0);
    if (at <= _samples.first.$1) return _samples.first.$2;
    for (var i = 0; i < _samples.length - 1; i++) {
      final (t0, p0) = _samples[i];
      final (t1, p1) = _samples[i + 1];
      if (at >= t0 && at <= t1) {
        final f = (at - t0) / (t1 - t0);
        return (p0.$1 + (p1.$1 - p0.$1) * f, p0.$2 + (p1.$2 - p0.$2) * f, 0.0);
      }
    }
    return _samples.last.$2;
  }
}
