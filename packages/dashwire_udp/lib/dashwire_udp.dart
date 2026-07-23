/// UDP transport for dashwire. dart:io platforms only.
///
/// Adds a reliability sublayer over datagrams, per-datagram acks with a
/// 32-bit history bitfield, ordered reliable delivery with bounded resends,
/// newest-wins sequencing for the unreliable channel, and fragmentation, plus
/// broadcast LAN discovery.
library;

export 'src/connection.dart' show UdpConfig, UdpConnection;
export 'src/discovery.dart' show LanAnnouncer, LanBeacon, LanBrowser;
export 'src/socket.dart' show UdpWireServer, connectUdp;
