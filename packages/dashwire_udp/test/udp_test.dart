@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dashwire/dashwire.dart';
import 'package:dashwire_udp/dashwire_udp.dart';
import 'package:test/test.dart';

const _fast = UdpConfig(
  resendInterval: Duration(milliseconds: 25),
  keepaliveInterval: Duration(milliseconds: 50),
);

UdpConfig _lossy(double loss, int seed) {
  final random = Random(seed);
  return UdpConfig(
    resendInterval: const Duration(milliseconds: 25),
    keepaliveInterval: const Duration(milliseconds: 50),
    debugDropOutboundPayload: () => random.nextDouble() < loss,
  );
}

Future<(WireConnection, WireConnection, UdpWireServer)> _pair({
  UdpConfig clientConfig = _fast,
  UdpConfig serverConfig = _fast,
}) async {
  final server = await UdpWireServer.bind(
    InternetAddress.loopbackIPv4,
    0,
    config: serverConfig,
  );
  final serverSide = server.connections.first;
  final client = await connectUdp(
    InternetAddress.loopbackIPv4,
    server.port,
    config: clientConfig,
  );
  return (client, await serverSide, server);
}

Future<void> _waitFor(
  bool Function() predicate, {
  Duration limit = const Duration(seconds: 8),
}) async {
  final sw = Stopwatch()..start();
  while (!predicate()) {
    if (sw.elapsed > limit) fail('condition not reached in $limit');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  test('connects and exchanges both channels', () async {
    final (client, remote, server) = await _pair();
    final atServer = remote.messages.take(2).toList();
    client.send(Channel.reliable, Uint8List.fromList([1]));
    client.send(Channel.unreliable, Uint8List.fromList([2]));
    final received = await atServer;
    expect(received[0].channel, Channel.reliable);
    expect(received[0].payload, [1]);
    expect(received[1].channel, Channel.unreliable);
    expect(received[1].payload, [2]);

    final atClient = client.messages.first;
    remote.send(Channel.reliable, Uint8List.fromList([3]));
    expect((await atClient).payload, [3]);
    await client.close();
    await server.close();
  });

  test('reliable messages all arrive in order through 30% loss', () async {
    final (client, remote, server) = await _pair(
      clientConfig: _lossy(0.3, 1),
      serverConfig: _lossy(0.3, 2),
    );
    const count = 150;
    final received = <int>[];
    final sub = remote.messages.listen((m) {
      if (m.channel == Channel.reliable) {
        received.add(ByteReader(m.payload).readU16());
      }
    });
    for (var i = 0; i < count; i++) {
      client.send(Channel.reliable, (ByteWriter(2)..writeU16(i)).toBytes());
    }
    await _waitFor(() => received.length == count);
    expect(received, List.generate(count, (i) => i));
    await sub.cancel();
    await client.close();
    await server.close();
  });

  test('fragmented reliable payloads survive loss intact', () async {
    final (client, remote, server) = await _pair(
      clientConfig: _lossy(0.2, 3),
      serverConfig: _lossy(0.2, 4),
    );
    final big = Uint8List.fromList(
      List.generate(10000, (i) => (i * 31 + 7) & 0xff),
    );
    final got = remote.messages.first;
    client.send(Channel.reliable, big);
    expect((await got).payload, big);
    await client.close();
    await server.close();
  });

  test('fragmented unreliable payloads reassemble without loss', () async {
    final (client, remote, server) = await _pair();
    final big = Uint8List.fromList(List.generate(5000, (i) => i & 0xff));
    final got = remote.messages.first;
    client.send(Channel.unreliable, big);
    final message = await got;
    expect(message.channel, Channel.unreliable);
    expect(message.payload, big);
    await client.close();
    await server.close();
  });

  test('reliable queue overflow closes the connection', () async {
    final config = UdpConfig(
      resendInterval: const Duration(milliseconds: 50),
      maxUnacked: 16,
      debugDropOutboundPayload: () => true,
    );
    final (client, _, server) = await _pair(clientConfig: config);
    expect(() {
      for (var i = 0; i < 20; i++) {
        client.send(Channel.reliable, Uint8List.fromList([i]));
      }
    }, throwsStateError);
    expect(client.isOpen, isFalse);
    await server.close();
  });

  test('silence times out the connection', () async {
    // A fake server that accepts the handshake and then goes silent.
    final socket = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      for (var d = socket.receive(); d != null; d = socket.receive()) {
        final r = ByteReader(d.data);
        if (r.readU8() != 0xd5 || r.readU8() != 1) continue;
        final clientSalt = r.readU32();
        final accept =
            (ByteWriter(12)
                  ..writeU8(0xd5)
                  ..writeU8(2)
                  ..writeU32(clientSalt)
                  ..writeU32(99))
                .toBytes();
        socket.send(accept, d.address, d.port);
      }
    });

    final client = await connectUdp(
      InternetAddress.loopbackIPv4,
      socket.port,
      config: const UdpConfig(
        keepaliveInterval: Duration(milliseconds: 40),
        timeout: Duration(milliseconds: 300),
      ),
    );
    await client.done.timeout(const Duration(seconds: 3));
    expect(client.isOpen, isFalse);
    socket.close();
  });

  test('keepalives hold an idle connection open', () async {
    final (client, remote, server) = await _pair(
      clientConfig: const UdpConfig(
        keepaliveInterval: Duration(milliseconds: 40),
        timeout: Duration(milliseconds: 400),
      ),
      serverConfig: const UdpConfig(
        keepaliveInterval: Duration(milliseconds: 40),
        timeout: Duration(milliseconds: 400),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 900));
    expect(client.isOpen, isTrue);
    expect(remote.isOpen, isTrue);
    await client.close();
    await server.close();
  });

  test('graceful close reaches the remote end', () async {
    final (client, remote, server) = await _pair();
    await client.close();
    await remote.done.timeout(const Duration(seconds: 2));
    expect(remote.isOpen, isFalse);
    await server.close();
  });

  test('a full session runs over UDP', () async {
    final server = await UdpWireServer.bind(InternetAddress.loopbackIPv4, 0);
    final listener = SessionListener(
      schemaHash: 0x11,
      tickRate: 60,
      currentTick: () => 5,
    );
    final acceptedFuture = server.connections.first.then(listener.accept);
    final session = await connectSession(
      await connectUdp(InternetAddress.loopbackIPv4, server.port),
      schemaHash: 0x11,
      pingInterval: const Duration(milliseconds: 40),
    );
    final serverSession = (await acceptedFuture)!;

    final got = serverSession.appMessages.first;
    session.sendApp(Channel.unreliable, Uint8List.fromList([7]));
    expect((await got).payload, [7]);
    await _waitFor(() => session.clock.isSynchronized);
    await session.close();
    await server.close();
  });

  test('LAN discovery beacons carry the advertised port and payload', () async {
    final browser = await LanBrowser.bind(0);
    final beaconFuture = browser.beacons.first;
    final announcer = await LanAnnouncer.start(
      discoveryPort: browser.port,
      advertisedPort: 4242,
      payload: Uint8List.fromList('dash arena'.codeUnits),
      interval: const Duration(milliseconds: 100),
      target: InternetAddress.loopbackIPv4,
    );
    final beacon = await beaconFuture.timeout(const Duration(seconds: 3));
    expect(beacon.port, 4242);
    expect(String.fromCharCodes(beacon.payload), 'dash arena');
    announcer.stop();
    browser.close();
  });
}
