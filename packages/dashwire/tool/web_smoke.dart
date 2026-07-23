// Compile target proving the public library builds under dart2js and
// dart2wasm. Exercised by CI, not shipped.
import 'package:dashwire/dashwire.dart';

void main() {
  final writer = ByteWriter()..writeVarUint(fnv1a32('dashwire'));
  final reader = ByteReader(writer.toBytes());
  print(reader.readVarUint());
}
