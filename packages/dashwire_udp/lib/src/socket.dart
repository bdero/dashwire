import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dashwire/dashwire.dart';

import 'connection.dart';
import 'packet.dart';

/// Connects to a [UdpWireServer] at [address]:[port].
///
/// The handshake exchanges salts (client picks one, server answers with its
/// own); their xor becomes the session id stamped on every later datagram.
Future<WireConnection> connectUdp(
  InternetAddress address,
  int port, {
  UdpConfig config = const UdpConfig(),
}) async {
  final socket = await RawDatagramSocket.bind(
    address.type == InternetAddressType.IPv6
        ? InternetAddress.anyIPv6
        : InternetAddress.anyIPv4,
    0,
  );
  final clientSalt = Random.secure().nextInt(0x100000000);
  final request =
      (ByteWriter(8)
            ..writeU8(magicByte)
            ..writeU8(PacketKind.connectRequest)
            ..writeU32(clientSalt))
          .toBytes();

  final accepted = Completer<int>();
  UdpConnection? connection;

  socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    for (var d = socket.receive(); d != null; d = socket.receive()) {
      final datagram = d;
      final established = connection;
      if (established != null) {
        established.handleDatagram(datagram.data);
        continue;
      }
      final r = ByteReader(datagram.data);
      if (r.remaining < 10 || r.readU8() != magicByte) continue;
      if (r.readU8() != PacketKind.connectAccept) continue;
      if (r.readU32() != clientSalt) continue;
      if (!accepted.isCompleted) accepted.complete(r.readU32());
    }
  });

  socket.send(request, address, port);
  final retry = Timer.periodic(
    config.connectRetryInterval,
    (_) => socket.send(request, address, port),
  );
  final int serverSalt;
  try {
    serverSalt = await accepted.future.timeout(config.connectTimeout);
  } on TimeoutException {
    socket.close();
    rethrow;
  } finally {
    retry.cancel();
  }

  connection = UdpConnection(
    sessionId: (clientSalt ^ serverSalt) & 0xffffffff,
    sendDatagram: (bytes) => socket.send(bytes, address, port),
    config: config,
    onClosed: (_) => socket.close(),
  );
  return connection;
}

/// A UDP server multiplexing one socket across peer connections.
final class UdpWireServer {
  UdpWireServer._(this._socket, this._config, this._serverSalt) {
    _socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      for (var d = _socket.receive(); d != null; d = _socket.receive()) {
        _handle(d);
      }
    });
  }

  static Future<UdpWireServer> bind(
    InternetAddress address,
    int port, {
    UdpConfig config = const UdpConfig(),
  }) async => UdpWireServer._(
    await RawDatagramSocket.bind(address, port),
    config,
    Random.secure().nextInt(0x100000000),
  );

  final RawDatagramSocket _socket;
  final UdpConfig _config;
  final int _serverSalt;
  final Map<String, UdpConnection> _peers = {};
  final _connections = StreamController<WireConnection>();

  int get port => _socket.port;

  /// Newly connected peers. Hand each to a SessionListener.
  Stream<WireConnection> get connections => _connections.stream;

  static String _key(InternetAddress address, int port) =>
      '${address.address}:$port';

  void _handle(Datagram datagram) {
    final key = _key(datagram.address, datagram.port);
    final r = ByteReader(datagram.data);
    if (r.remaining < 2 || r.readU8() != magicByte) return;
    final kind = r.readU8();

    if (kind == PacketKind.connectRequest) {
      if (r.remaining < 4) return;
      final clientSalt = r.readU32();
      final accept =
          (ByteWriter(12)
                ..writeU8(magicByte)
                ..writeU8(PacketKind.connectAccept)
                ..writeU32(clientSalt)
                ..writeU32(_serverSalt))
              .toBytes();
      _socket.send(accept, datagram.address, datagram.port);
      if (!_peers.containsKey(key)) {
        final connection = UdpConnection(
          sessionId: (clientSalt ^ _serverSalt) & 0xffffffff,
          sendDatagram: (bytes) =>
              _socket.send(bytes, datagram.address, datagram.port),
          config: _config,
          onClosed: (_) => _peers.remove(key),
        );
        _peers[key] = connection;
        _connections.add(connection);
      }
      return;
    }
    _peers[key]?.handleDatagram(datagram.data);
  }

  Future<void> close() async {
    for (final peer in List.of(_peers.values)) {
      await peer.close();
    }
    _socket.close();
    await _connections.close();
  }
}
