import 'dart:convert';

/// 32-bit FNV-1a over the UTF-8 encoding of [input].
///
/// Used for schema and endpoint name hashes. The FNV prime multiply is
/// decomposed into shift-adds (prime 0x01000193 = 1 + 2^1 + 2^4 + 2^7 +
/// 2^8 + 2^24) whose intermediate sums stay under 2^53, so results are
/// identical on the VM, dart2js, and dart2wasm.
int fnv1a32(String input) {
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(input)) {
    hash ^= byte;
    hash =
        (hash +
            ((hash << 1) & 0xffffffff) +
            ((hash << 4) & 0xffffffff) +
            ((hash << 7) & 0xffffffff) +
            ((hash << 8) & 0xffffffff) +
            ((hash << 24) & 0xffffffff)) &
        0xffffffff;
  }
  return hash;
}
