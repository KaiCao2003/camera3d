import Foundation
import simd

/// One authoritative mapping from BrainGlobe's ASR micron coordinates into
/// BrainBuilder scene axes: right, dorsal, posterior.
enum AtlasSceneGeometry {
    static func scenePoint(
        atlasASRMicrons point: SIMD3<Double>,
        atlasCenterMicrons center: SIMD3<Double>,
        sceneMicronsPerUnit scale: Double
    ) -> SIMD3<Float>? {
        guard scale.isFinite, scale > 0,
              point.x.isFinite, point.y.isFinite, point.z.isFinite,
              center.x.isFinite, center.y.isFinite, center.z.isFinite else {
            return nil
        }
        let mapped = SIMD3<Double>(
            (center.z - point.z) / scale,
            (center.y - point.y) / scale,
            (point.x - center.x) / scale
        )
        guard mapped.x.isFinite, mapped.y.isFinite, mapped.z.isFinite else {
            return nil
        }
        return SIMD3<Float>(Float(mapped.x), Float(mapped.y), Float(mapped.z))
    }

    static func sceneTransform(
        atlasCenterMicrons center: SIMD3<Double>,
        sceneMicronsPerUnit scale: Double
    ) -> simd_float4x4? {
        guard scale.isFinite, scale > 0,
              center.x.isFinite, center.y.isFinite, center.z.isFinite else {
            return nil
        }
        let inverseScale = Float(1 / scale)
        return simd_float4x4(columns: (
            SIMD4<Float>(0, 0, inverseScale, 0),
            SIMD4<Float>(0, -inverseScale, 0, 0),
            SIMD4<Float>(-inverseScale, 0, 0, 0),
            SIMD4<Float>(
                Float(center.z / scale),
                Float(center.y / scale),
                Float(-center.x / scale),
                1
            )
        ))
    }
}
