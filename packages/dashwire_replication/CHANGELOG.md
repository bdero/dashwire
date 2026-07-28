# Changelog

## 0.1.0

- Replicated-property schema: `Replica`/`rep<T>`/`rpc` with write and read permission axes and per-field replication modes.
- Sync pipeline: per-connection acked baselines with change-bit delta encoding, quantized codecs (varint, quantized float, vec3, smallest-three quaternion, bool-packing), and importance-versus-starvation priority packing against a byte budget.
- Spawn/despawn with a prefab registry, dormancy with auto-wake, and relevancy filters (always-relevant, per-connection, spatial grid, dependent edges).
- Ownership-checked RPCs with validation tripwires.
- Rooms with fixed tick and an isolate-per-room pool (`package:dashwire_replication/server.dart`), plus `RoomStore` snapshot/hydrate.
- `TransformReplica`, a pose-carrying replica base for shared game schemas.
