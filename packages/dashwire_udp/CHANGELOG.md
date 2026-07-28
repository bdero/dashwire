# Changelog

## 0.1.0

- UDP transport: sequencing with piggybacked ack bitfields, fragmentation over MTU, and a bounded reliable resend queue that disconnects on overflow.
- Maps the reliable and unreliable channels onto a single socket.
- UDP broadcast LAN discovery helper.
