# Changelog

## Unreleased

- `Predictor<I,S>`, a generic client-side prediction engine with input-replay reconciliation (advance per tick, roll back to an authoritative state and replay the not-yet-applied inputs).
- `LagCompensation<K,V>`, a server-side per-tick history that rewinds tracked entities to the client-rendered tick (interpolated, capped) for lag-compensated hit resolution.
- `ReplicationHost.priorityScale`, a per-connection snapshot-priority multiplier (the distance-falloff generalization); the priority accumulator is now per connection so scaling stays starvation-fair.
- Tick-indexed input commands, `ReplicationClient.sendInput` with a redundant unreliable tail that self-heals dropped packets, `ReplicationHost.consumeInput`/`Room.input` for authoritative per-tick consumption with hold-last on a miss, and server-driven send-ahead pacing from a per-connection buffer-depth ack. The substrate for client prediction and input-replay reconciliation.
- Fixed quantizing codec ids rendering differently under dart2js, which made a native host and a web client disagree on the schema hash and reject the join.
- Fixed a leave race where despawning the leaver's entity in a room's `onLeave` sent on its closed connection.

## 0.1.0

- Replicated-property schema: `Replica`/`rep<T>`/`rpc` with write and read permission axes and per-field replication modes.
- Sync pipeline: per-connection acked baselines with change-bit delta encoding, quantized codecs (varint, quantized float, vec3, smallest-three quaternion, bool-packing), and importance-versus-starvation priority packing against a byte budget.
- Spawn/despawn with a prefab registry, dormancy with auto-wake, and relevancy filters (always-relevant, per-connection, spatial grid, dependent edges).
- Ownership-checked RPCs with validation tripwires.
- Rooms with fixed tick and an isolate-per-room pool (`package:dashwire_replication/server.dart`), plus `RoomStore` snapshot/hydrate.
- `TransformReplica`, a pose-carrying replica base for shared game schemas.
