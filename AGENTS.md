# Working in dashwire

Development conventions for this repo. Claude Code reads this via the `CLAUDE.md` symlink.

## Writing conventions

- No em dashes anywhere, ever. Use commas, parentheses, or separate sentences.
- Avoid colons in prose where a comma or reword works just as well. No `Label: explanation` comment shape.
- No spaces around a separating `/`. Write `a/b`.
- Comments and docstrings as tight as possible, no throat-clearing, no restating the code.
- Code, comments, and commits stand alone. No phase/milestone/roadmap terminology and no references to external working notes.
- Always leave a `TODO(topic): ...` for anything deferred, approximated, or shortcut.
- Do not mention Claude or AI anywhere, code, comments, commits, PR/issue text.
- Do not hard-wrap paragraphs in PR descriptions or issue bodies.

## Repo rules

- Prefix every branch with `bdero/`. `master` is the default branch.
- Never open a PR, file an issue, or publish a package unless explicitly asked.
- Every package sets `publish_to: none` until the coordinated first release; do not remove it.
- The repo is private until that release. Do not make it public, add collaborators, or reference it from public places.

## Engineering rules

- **No Flutter, ever.** No package here may depend on the Flutter SDK or import `dart:ui`. CI installs only the plain Dart SDK, so a violation fails resolution immediately. Target the Dart stable channel, not master.
- **Web is a first-class target** for `dashwire` and `dashwire_replication`. Code shared with the web must compile under dart2js and dart2wasm; platform-specific transports use conditional imports with a throwing fallback stub.
- **32-bit lanes on the wire.** dart2js ints are 53-bit with 32-bit bitwise ops, so wire encodings, hashes, and packed fields never rely on bit positions above 31 or on int64. Plain int counters (ticks) may exceed 32 bits but are varint-encoded, never bit-packed.
- **Golden byte tests for every wire format.** Any change to an encoding needs a test asserting exact bytes, not just a round trip.
- **Protocol code cites its source.** Implementations of standardized behavior (LEB128, RFC state machines) name the spec and section in a comment at the top of the file.
- **Public API is show-listed.** Package barrels export symbols with explicit `show` lists; nothing under `lib/src` is public surface.
- **Keep the hot path allocation-light.** Per-tick code reuses buffers; no per-field boxing on serialize paths.

## Formatting

CI checks `dart format` from the stable SDK. Local development on a Flutter-fork Dart may format differently; when in doubt run the format check with a stable-channel `dart`, or `dart pub global activate dart_style` and `dart pub global run dart_style:format`.
