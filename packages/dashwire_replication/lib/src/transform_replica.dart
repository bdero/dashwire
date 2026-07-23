import 'codec.dart';
import 'schema.dart';

/// A [Replica] carrying a world pose, the conventional base for anything an
/// engine-side transform component can drive.
///
/// The base constructor registers `position` and `rotation` before subclass
/// constructor bodies run, so subclass fields append after them in wire
/// order. Pose types are dependency-free records; engine layers adapt their
/// own vector types at the boundary.
abstract base class TransformReplica extends Replica {
  TransformReplica({double positionResolution = 0.001}) {
    position = rep('position', (
      0.0,
      0.0,
      0.0,
    ), codec: Codecs.vec3(positionResolution));
    rotation = rep('rotation', (0.0, 0.0, 0.0, 1.0), codec: Codecs.quat);
  }

  late final Rep<Vec3> position;
  late final Rep<Quat> rotation;
}
