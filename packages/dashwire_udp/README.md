# dashwire_udp

A reliable UDP transport for [dashwire](https://github.com/bdero/dashwire).

This package layers ordering and reliability over UDP:

- Sequencing with piggybacked ack bitfields.
- Fragmentation over the MTU and reassembly.
- A bounded reliable resend queue that disconnects on overflow.
- The reliable and unreliable dashwire channels mapped onto a single socket.
- A UDP broadcast helper for LAN discovery.

Depends on [`dashwire`](https://pub.dev/packages/dashwire) for the transport abstraction and wire primitives.

## Compatibility

Pure Dart, no Flutter dependency. Native only (UDP sockets are unavailable on web).
