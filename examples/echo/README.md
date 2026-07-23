# echo

Session echo demo.

```sh
dart run bin/server.dart          # serves ws + static on :8080
dart run bin/client.dart          # console client, type lines
```

Browser client

```sh
dart compile js web/main.dart -o web/main.dart.js
# then open http://localhost:8080 and watch the devtools console
```
