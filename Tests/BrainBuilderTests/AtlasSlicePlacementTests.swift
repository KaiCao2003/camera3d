import XCTest
@testable import BrainBuilder

final class AtlasSlicePlacementTests: XCTestCase {
    func testInverseAffinePlacesCanonicalSlicePixelAtAtlasCenter() throws {
        let placement = AtlasSlicePlacement(
            sliceToAtlasPlane: AffineTransform2D(
                m00: 1,
                m01: 0,
                m10: 0,
                m11: 1,
                tx: -100,
                ty: -50
            ),
            pixelSizeMicrons: 10,
            planeSize: PixelSize(width: 100, height: 80),
            atlasOriginIndex: SIMD3<Double>(10, 20, 30),
            atlasUIndex: SIMD3<Double>(0, 0, 100),
            atlasVIndex: SIMD3<Double>(0, 80, 0),
            atlasResolutionMicrons: SIMD3<Double>(10, 10, 10),
            atlasCenterMicrons: SIMD3<Double>(100, 600, 800),
            sceneMicronsPerUnit: 1_000,
            isReviewed: true
        )

        let center = try XCTUnwrap(placement.scenePoint(pixelX: 60, pixelY: 45))

        XCTAssertEqual(center.x, 0, accuracy: 0.000_001)
        XCTAssertEqual(center.y, 0, accuracy: 0.000_001)
        XCTAssertEqual(center.z, 0, accuracy: 0.000_001)
    }

    func testAtlasBasisPreservesLiteralAPDistanceAndSceneAxisDirections() throws {
        let placement = AtlasSlicePlacement(
            sliceToAtlasPlane: .identity,
            pixelSizeMicrons: 10,
            planeSize: PixelSize(width: 100, height: 100),
            atlasOriginIndex: SIMD3<Double>(40, 10, 20),
            atlasUIndex: SIMD3<Double>(20, 0, 100),
            atlasVIndex: SIMD3<Double>(0, 100, 0),
            atlasResolutionMicrons: SIMD3<Double>(25, 25, 25),
            atlasCenterMicrons: SIMD3<Double>(1_250, 1_500, 1_750),
            sceneMicronsPerUnit: 5_000,
            isReviewed: false
        )

        let origin = try XCTUnwrap(placement.scenePoint(pixelX: 0, pixelY: 0))
        let rightEdge = try XCTUnwrap(placement.scenePoint(pixelX: 100, pixelY: 0))
        let ventralEdge = try XCTUnwrap(placement.scenePoint(pixelX: 0, pixelY: 100))

        XCTAssertEqual(rightEdge.z - origin.z, 500 / 5_000, accuracy: 0.000_001)
        XCTAssertEqual(rightEdge.x - origin.x, -2_500 / 5_000, accuracy: 0.000_001)
        XCTAssertEqual(ventralEdge.y - origin.y, -2_500 / 5_000, accuracy: 0.000_001)
    }
}
