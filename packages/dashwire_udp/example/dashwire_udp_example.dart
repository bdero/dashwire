// Announce a game on the LAN and discover it from the same process, over the
// loopback interface. On a real network the browser runs on other devices.
import 'dart:io';
import 'dart:typed_data';

import 'package:dashwire_udp/dashwire_udp.dart';

Future<void> main() async {
  const discoveryPort = 45999;

  final browser = await LanBrowser.bind(discoveryPort);
  final beacon = browser.beacons.first;

  final announcer = await LanAnnouncer.start(
    discoveryPort: discoveryPort,
    advertisedPort: 7777,
    payload: Uint8List.fromList('dash-arena'.codeUnits),
    target: InternetAddress.loopbackIPv4,
  );

  final found = await beacon;
  print(
    'found game on port ${found.port}: ${String.fromCharCodes(found.payload)}',
  );

  announcer.stop();
  browser.close();
}
