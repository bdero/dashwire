/// Replicated state for dashwire, a property schema with permission axes,
/// snapshot/delta sync, relevancy, spawning, and RPCs.
library;

export 'src/codec.dart' show Codec, Codecs, Quat, Vec3;
export 'src/net_id.dart' show NetId, NetIdAllocator;
export 'src/schema.dart'
    show
        Authority,
        Delivery,
        ReadScope,
        Rep,
        RepField,
        Replica,
        ReplicaRegistry,
        RpcEndpoint,
        RpcTarget,
        SendMode,
        StructCodec,
        encodeAllFields,
        voidCodec;
export 'src/room/room.dart' show MemoryRoomStore, Room, RoomStore;
export 'src/sync/client.dart' show ReplicationClient;
export 'src/sync/host.dart' show HostConfig, ReplicationHost;
export 'src/sync/relevancy.dart' show RelevancyFilter, SpatialGridFilter;
