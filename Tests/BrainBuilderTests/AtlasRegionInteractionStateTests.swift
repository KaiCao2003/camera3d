import XCTest
@testable import BrainBuilder

final class AtlasRegionInteractionStateTests: XCTestCase {
    func testHoverTemporarilyOverridesPinAndFallsBackWhenHoverEnds() {
        var state = AtlasRegionInteractionState()
        state.synchronize(to: context(sliceID: "slice-a", annotationPath: "/atlas/a.tif"))
        let pinned = region(id: 385, acronym: "VISp", name: "Primary visual area", x: 10)
        let preview = region(id: 821, acronym: "VISp2/3", name: "Primary visual area, layer 2/3", x: 20)

        state.pin(pinned)
        state.updateHover(preview)

        XCTAssertEqual(state.displayedRegion, preview)
        XCTAssertTrue(state.isDisplayingPreview)
        XCTAssertEqual(state.pinnedRegion, pinned)

        state.updateHover(nil)

        XCTAssertEqual(state.displayedRegion, pinned)
        XCTAssertFalse(state.isDisplayingPreview)
    }

    func testValidTapAlwaysPinsLatestHitAndUnmappedTapPreservesPin() {
        var state = AtlasRegionInteractionState()
        state.synchronize(to: context(sliceID: "slice-a", annotationPath: "/atlas/a.tif"))
        let firstPoint = region(id: 385, acronym: "VISp", name: "Primary visual area", x: 10)
        let laterPointInSameRegion = region(id: 385, acronym: "VISp", name: "Primary visual area", x: 42)

        state.pin(firstPoint)
        state.pin(laterPointInSameRegion)
        XCTAssertEqual(state.pinnedRegion, laterPointInSameRegion)

        state.pin(nil)
        XCTAssertEqual(state.pinnedRegion, laterPointInSameRegion)
    }

    func testPinImmediatelyWinsOverTheHoverAtTheClickLocation() {
        var state = AtlasRegionInteractionState()
        state.synchronize(to: context(sliceID: "slice-a", annotationPath: "/atlas/a.tif"))
        let hit = region(id: 385, acronym: "VISp", name: "Primary visual area", x: 10)
        state.updateHover(hit)

        state.pin(hit)

        XCTAssertEqual(state.displayedRegion, hit)
        XCTAssertEqual(state.pinnedRegion, hit)
        XCTAssertFalse(state.isDisplayingPreview)
    }

    func testSelectionSurvivesSameContextAndClearsWhenSliceOrAnnotationChanges() {
        var state = AtlasRegionInteractionState()
        let original = context(sliceID: "slice-a", annotationPath: "/atlas/a.tif")
        let pinned = region(id: 385, acronym: "VISp", name: "Primary visual area", x: 10)
        state.synchronize(to: original)
        state.pin(pinned)

        XCTAssertFalse(state.synchronize(to: original))
        XCTAssertEqual(state.pinnedRegion, pinned)

        XCTAssertTrue(state.synchronize(to: context(sliceID: "slice-b", annotationPath: "/atlas/a.tif")))
        XCTAssertNil(state.pinnedRegion)

        state.pin(pinned)
        XCTAssertTrue(state.synchronize(to: context(sliceID: "slice-b", annotationPath: "/atlas/b.tif")))
        XCTAssertNil(state.pinnedRegion)
    }

    func testRegistrationRevisionReloadsAnnotationAndClearsStalePin() {
        var state = AtlasRegionInteractionState()
        let firstRevision = Date(timeIntervalSince1970: 1_000)
        let secondRevision = Date(timeIntervalSince1970: 2_000)
        let original = context(
            sliceID: "slice-a",
            annotationPath: "/atlas/annotation-ids.tif",
            registrationRevision: firstRevision
        )
        let pinned = region(id: 385, acronym: "VISp", name: "Primary visual area", x: 10)
        state.synchronize(to: original)
        state.pin(pinned)

        XCTAssertTrue(
            state.synchronize(
                to: context(
                    sliceID: "slice-a",
                    annotationPath: "/atlas/annotation-ids.tif",
                    registrationRevision: secondRevision
                )
            )
        )
        XCTAssertNil(state.pinnedRegion)
    }

    func testTrackRoundTripClearsPreviewButPreservesPinnedContext() {
        var state = AtlasRegionInteractionState()
        state.synchronize(to: context(sliceID: "slice-a", annotationPath: "/atlas/a.tif"))
        let pinned = region(id: 385, acronym: "VISp", name: "Primary visual area", x: 10)
        let preview = region(id: 821, acronym: "VISp2/3", name: "Primary visual area, layer 2/3", x: 20)
        state.pin(pinned)
        state.updateHover(preview)

        state.setDirectLookupEnabled(false)

        XCTAssertNil(state.hoveredRegion)
        XCTAssertEqual(state.displayedRegion, pinned)
        XCTAssertEqual(state.pinnedRegion, pinned)

        state.setDirectLookupEnabled(true)

        XCTAssertEqual(state.displayedRegion, pinned)
        XCTAssertEqual(state.pinnedRegion, pinned)
    }

    func testClearPinIsExplicitAndDoesNotDiscardCurrentHover() {
        var state = AtlasRegionInteractionState()
        state.synchronize(to: context(sliceID: "slice-a", annotationPath: "/atlas/a.tif"))
        let pinned = region(id: 385, acronym: "VISp", name: "Primary visual area", x: 10)
        let preview = region(id: 821, acronym: "VISp2/3", name: "Primary visual area, layer 2/3", x: 20)
        state.pin(pinned)
        state.updateHover(preview)

        state.clearPin()

        XCTAssertNil(state.pinnedRegion)
        XCTAssertEqual(state.displayedRegion, preview)
    }

    private func context(
        sliceID: String,
        annotationPath: String?,
        registrationRevision: Date? = nil
    ) -> AtlasRegionInteractionContext {
        AtlasRegionInteractionContext(
            sliceID: sliceID,
            annotationPath: annotationPath,
            structuresPath: "/atlas/structures.json",
            registrationRevision: registrationRevision
        )
    }

    private func region(
        id: UInt32,
        acronym: String,
        name: String,
        x: Int
    ) -> AtlasRegionHit {
        AtlasRegionHit(
            structureID: id,
            acronym: acronym,
            name: name,
            rgbTriplet: [8, 133, 140],
            ancestry: [],
            annotationX: x,
            annotationY: 7,
            isKnownStructure: true
        )
    }
}
