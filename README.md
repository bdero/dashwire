# dashwire

Multiplayer networking for Dart games. Engine-agnostic transport, replication, and rooms, usable from any Dart or Flutter project.

| Package | pub.dev | What it is |
| --- | --- | --- |
| `dashwire` | [![pub](https://img.shields.io/pub/v/dashwire.svg)](https://pub.dev/packages/dashwire) | Transport abstraction, channels, session/handshake, clock and tick sync, loopback and WebSocket transports, network simulator. |
| `dashwire_udp` | [![pub](https://img.shields.io/pub/v/dashwire_udp.svg)](https://pub.dev/packages/dashwire_udp) | Reliability layer over UDP (sequencing, acks, fragmentation) plus LAN discovery. |
| `dashwire_replication` | [![pub](https://img.shields.io/pub/v/dashwire_replication.svg)](https://pub.dev/packages/dashwire_replication) | Replicated-property schema, snapshot/delta sync, relevancy, spawning, RPCs, rooms. |

## Developing

This is a pub workspace. From the repo root

```sh
dart pub get
dart analyze
dart test packages/dashwire
```

No package in this repo may depend on Flutter; CI runs with the plain Dart SDK only, so a Flutter dependency fails resolution immediately.
