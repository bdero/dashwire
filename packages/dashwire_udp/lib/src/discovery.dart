import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dashwire/dashwire.dart';

const int _beaconMagic = 0xd6;

/// A received LAN announcement.
final class LanBeacon {
  LanBeacon(this.address, this.port, this.payload);

  /// Announcer address and the game port it advertised.
  final InternetAddress address;
  final int port;

  /// App-defined bytes (server name, player count, ...).
  final Uint8List payload;
}

/// Periodically broadcasts a beacon so [LanBrowser]s can find this host.
///
/// Plain broadcast to 255.255.255.255, dependable on desktop; multicast is
/// deliberately not used (mobile-platform entitlement and reliability
/// problems).
final class LanAnnouncer {
  LanAnnouncer._(this._socket, this._timer);

  /// Announces [advertisedPort] and [payload] every [interval] to
  /// [discoveryPort]. [target] overrides the broadcast address (tests use
  /// loopback).
  static Future<LanAnnouncer> start({
    required int discoveryPort,
    required int advertisedPort,
    required Uint8List payload,
    Duration interval = const Duration(seconds: 1),
    InternetAddress? target,
  }) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;
    final to = target ?? InternetAddress('255.255.255.255');
    final beacon =
        (ByteWriter(payload.length + 4)
              ..writeU8(_beaconMagic)
              ..writeU16(advertisedPort)
              ..writeLengthPrefixedBytes(payload))
            .toBytes();
    void announce() => socket.send(beacon, to, discoveryPort);
    announce();
    return LanAnnouncer._(socket, Timer.periodic(interval, (_) => announce()));
  }

  final RawDatagramSocket _socket;
  final Timer _timer;

  void stop() {
    _timer.cancel();
    _socket.close();
  }
}

/// Listens for [LanAnnouncer] beacons on a discovery port.
final class LanBrowser {
  LanBrowser._(this._socket) {
    _socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      for (var d = _socket.receive(); d != null; d = _socket.receive()) {
        final r = ByteReader(d.data);
        if (r.remaining < 3 || r.readU8() != _beaconMagic) continue;
        final port = r.readU16();
        final payload = Uint8List.fromList(r.readLengthPrefixedBytes());
        _beacons.add(LanBeacon(d.address, port, payload));
      }
    });
  }

  static Future<LanBrowser> bind(int discoveryPort) async => LanBrowser._(
    await RawDatagramSocket.bind(InternetAddress.anyIPv4, discoveryPort),
  );

  final RawDatagramSocket _socket;
  final _beacons = StreamController<LanBeacon>();

  int get port => _socket.port;

  Stream<LanBeacon> get beacons => _beacons.stream;

  void close() {
    _socket.close();
    _beacons.close();
  }
}
