# arena

Top-down multiplayer arena proving the whole stack end to end, lobby, room isolates, replication, owner-authority input, spatialless AoI (everything relevant), interpolation.

```sh
dart compile js web/main.dart -o web/main.dart.js
dart run bin/server.dart            # lobby on :8080, two room isolates
# open http://localhost:8080 in a couple of tabs, WASD/arrows to move
```

Bots/load smoke (also used as an end-to-end check)

```sh
dart run bin/load.dart http://localhost:8080 8 10
```
