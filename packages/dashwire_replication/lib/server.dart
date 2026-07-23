/// Server-only pieces of dashwire_replication (dart:isolate).
///
/// Import in server binaries alongside the main library; never from code
/// that must compile for the web.
library;

export 'src/room/isolate_pool.dart'
    show IsolateRoomPool, RoomHandle, RoomLaunch;
