# Changelog

## 0.1.0

- Wire primitives: `ByteWriter`/`ByteReader` (little-endian, varints, f32, length-prefixed strings), 32-bit `fnv1a32` name hash.
- Transport abstraction: `Channel`/`NetMessage`/`WireConnection`, `LoopbackConnection`, WebSocket transport (native and web), and a latency/jitter/loss/duplication `SimulatorConnection`.
- Session layer: versioned handshake with schema-hash slot and peer-id assignment, per-connection `ByteBudget` accounting.
- `NetClock` server-tick sync and a fixed-timestep `TickLoop`.
