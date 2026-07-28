# dashwire_replication

Replicated state for [dashwire](https://github.com/bdero/dashwire). A push-model, byte-budgeted replication layer for Dart multiplayer games.

This package provides:

- A replicated-property schema (`Replica`, `rep<T>`, `rpc`) with write and read permission axes and per-field replication modes, no codegen or reflection.
- Per-connection acked baselines with change-bit delta encoding and quantized codecs (varint, quantized float, vec3, smallest-three quaternion, bool-packing).
- Importance-versus-starvation priority packing against a per-connection byte budget.
- Spawn/despawn with a prefab registry, dormancy with auto-wake, and relevancy filters (always-relevant, per-connection, spatial grid, dependent edges).
- Ownership-checked RPCs with validation tripwires.
- Rooms with a fixed tick and an isolate-per-room pool (`package:dashwire_replication/server.dart`), plus `RoomStore` snapshot/hydrate.

Depends on [`dashwire`](https://pub.dev/packages/dashwire) for transport, session, and tick.

## Compatibility

Pure Dart, no Flutter dependency. Compiles for native, dart2js, and dart2wasm.
