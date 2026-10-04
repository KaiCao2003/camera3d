import XCTest
@testable import BrainBuilder

final class RegistrationViewportTests: XCTestCase {
    func testFitPreservesOriginalImageGeometry() {
        let viewport = RegistrationCanvasViewport(
            containerSize: CGSize(width: 800, height: 500),
            zoom: 1,
            pan: .zero
        )
        let fitted = AtlasImageGeometry.aspectFitRect(
            imageSize: CGSize(width: 320, height: 400),
            containerSize: viewport.containerSize
        )

        XCTAssertEqual(viewport.displayRect(fitted), fitted)
        XCTAssertEqual(viewport.imagePoint(CGPoint(x: 247, y: 381)), CGPoint(x: 247, y: 381))
    }

    func testZoomedAndPannedRegionMarkersResolveToTheSameAnnotationPixels() throws {
        let imageSize = CGSize(width: 320, height: 400)
        let pixels = [(0, 0), (319, 399), (42, 217), (160, 200)]

        for containerSize in [CGSize(width: 900, height: 500), CGSize(width: 420, height: 700)] {
            for zoom in [CGFloat(1), 2.5, 8] {
                for pan in [CGSize.zero, CGSize(width: -137, height: 83)] {
                    let viewport = RegistrationCanvasViewport(containerSize: containerSize, zoom: zoom, pan: pan)
                    for (x, y) in pixels {
                        let original = try XCTUnwrap(AtlasImageGeometry.containerPoint(
                            annotationX: x,
                            annotationY: y,
                            imageSize: imageSize,
                            containerSize: containerSize
                        ))
                        let displayedMarker = viewport.displayPoint(original)
                        let hit = try XCTUnwrap(AtlasImageGeometry.annotationPixel(
                            at: viewport.imagePoint(displayedMarker),
                            imageSize: imageSize,
                            containerSize: containerSize
                        ))
                        XCTAssertEqual(hit.x, x)
                        XCTAssertEqual(hit.y, y)
                    }
                }
            }
        }
    }

    func testZoomedLetterboxDoesNotInferAnAtlasRegion() {
        let imageSize = CGSize(width: 320, height: 400)
        let viewport = RegistrationCanvasViewport(
            containerSize: CGSize(width: 800, height: 500),
            zoom: 3,
            pan: CGSize(width: 100, height: -75)
        )
        let fitted = AtlasImageGeometry.aspectFitRect(
            imageSize: imageSize,
            containerSize: viewport.containerSize
        )
        let outsideImage = CGPoint(x: fitted.minX - 1, y: fitted.midY)
        let hit = AtlasImageGeometry.annotationPixel(
            at: viewport.imagePoint(viewport.displayPoint(outsideImage)),
            imageSize: imageSize,
            containerSize: viewport.containerSize
        )
        XCTAssertNil(hit)
    }
}
