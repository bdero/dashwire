# dashwire

Multiplayer networking for Dart games. The transport, session, and tick core of the [dashwire](https://github.com/bdero/dashwire) family, engine-agnostic and usable from any Dart or Flutter project.

This package provides:

- Wire primitives: `ByteWriter`/`ByteReader` (little-endian, varints, f32, length-prefixed strings) and a 32-bit `fnv1a32` name hash.
- A transport abstraction (`Channel`, `NetMessage`, `WireConnection`) with loopback and WebSocket transports (native and web) and a network condition `SimulatorConnection` for latency, jitter, loss, and duplication.
- A versioned session handshake with peer-id assignment and per-connection `ByteBudget` accounting.
- `NetClock` server-tick synchronization and a fixed-timestep `TickLoop`.

Replicated state lives in [`dashwire_replication`](https://pub.dev/packages/dashwire_replication); a reliable UDP transport lives in [`dashwire_udp`](https://pub.dev/packages/dashwire_udp).

## Compatibility

Pure Dart, no Flutter dependency. Compiles for native, dart2js, and dart2wasm.
