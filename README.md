# dashwire

Multiplayer networking for Dart games. Engine-agnostic transport, replication, and rooms, usable from any Dart or Flutter project.

Private while under initial development; nothing here is published yet.

| Package | What it is |
| --- | --- |
| `packages/dashwire` | Transport abstraction, channels, session/handshake, clock and tick sync, loopback and WebSocket transports, network simulator. |
| `packages/dashwire_udp` | Reliability layer over UDP (sequencing, acks, fragmentation) plus LAN discovery. |
| `packages/dashwire_replication` | Replicated-property schema, snapshot/delta sync, relevancy, spawning, RPCs, rooms. |

## Developing

This is a pub workspace. From the repo root

```sh
dart pub get
dart analyze
dart test packages/dashwire
```

No package in this repo may depend on Flutter; CI runs with the plain Dart SDK only, so a Flutter dependency fails resolution immediately.
