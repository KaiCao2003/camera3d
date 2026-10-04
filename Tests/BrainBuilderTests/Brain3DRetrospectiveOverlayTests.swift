import Foundation
import XCTest
@testable import BrainBuilder

final class Brain3DRetrospectiveOverlayTests: XCTestCase {
    func testSnapshotFailsClosedUntilBlindLockAndRetainsRetrospectiveBoundary() throws {
        var context = makeContext(locked: false)

        XCTAssertNil(Brain3DRetrospectiveOverlaySnapshot.locked(context: nil))
        XCTAssertNil(Brain3DRetrospectiveOverlaySnapshot.locked(context: context))

        context.blindReviewLocked = true
        let snapshot = try XCTUnwrap(
            Brain3DRetrospectiveOverlaySnapshot.locked(context: context)
        )

        XCTAssertEqual(snapshot.plannedShanks.map(\.shankId), ["shank-0"])
        XCTAssertEqual(snapshot.observedTracks.map(\.trackId), ["track-1"])
        XCTAssertEqual(snapshot.allenROIs.map(\.structureID), [500])
        XCTAssertTrue(snapshot.allenROIs[0].includeDescendants)
        XCTAssertEqual(snapshot.asrBoxes.map(\.boxID), ["box-1"])
        XCTAssertFalse(snapshot.usableForNavigation)

        context.reviewPreview?.tracks[0].usableForNavigation = true
        XCTAssertNil(Brain3DRetrospectiveOverlaySnapshot.locked(context: context))
    }

    func testAtlasPlaneProjectionClipsFiniteSupportsAndIntersectsASRBox() throws {
        let placement = coronalPlacement()
        let inPlane = Brain3DRetrospectiveSegment(
            id: "observed-1",
            endpointAASRMicrometres: SIMD3<Double>(1_000, 100, 200),
            endpointBASRMicrometres: SIMD3<Double>(1_000, 700, 800),
            kind: .observedEvidence
        )
        let projected = try XCTUnwrap(
            Brain3DRetrospectiveOverlayGeometry.sliceSegment(
                inPlane,
                placement: placement
            )
        )
        XCTAssertEqual(projected[0].x, 20, accuracy: 0.000_001)
        XCTAssertEqual(projected[0].y, 10, accuracy: 0.000_001)
        XCTAssertEqual(projected[1].x, 80, accuracy: 0.000_001)
        XCTAssertEqual(projected[1].y, 70, accuracy: 0.000_001)

        let outsideParallel = Brain3DRetrospectiveSegment(
            id: "outside",
            endpointAASRMicrometres: SIMD3<Double>(1_200, 100, 200),
            endpointBASRMicrometres: SIMD3<Double>(1_200, 700, 800),
            kind: .plannedShank
        )
        XCTAssertNil(
            Brain3DRetrospectiveOverlayGeometry.sliceSegment(
                outsideParallel,
                placement: placement
            )
        )

        let box = Brain3DLockedASRBoxROI(
            roiSetID: "roi-1",
            roiSetName: "Box",
            boxID: "box-1",
            minimumASRMicrometres: SIMD3<Double>(900, 200, 200),
            maximumASRMicrometres: SIMD3<Double>(1_100, 600, 800)
        )
        let polygon = Brain3DRetrospectiveOverlayGeometry.sliceBoxPolygon(
            box,
            placement: placement
        )
        XCTAssertEqual(polygon.count, 4)
        XCTAssertEqual(try XCTUnwrap(polygon.map(\.x).min()), 20, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(polygon.map(\.x).max()), 80, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(polygon.map(\.y).min()), 20, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(polygon.map(\.y).max()), 60, accuracy: 0.000_001)
    }

    func testAllenMaskUsesExactLabelsAndOptionalDescendants() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("brain3d-overlay-mask-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let structures = folder.appendingPathComponent("structures.json")
        let annotation = folder.appendingPathComponent("annotation-ids.tif")
        try ontologyJSON.write(to: structures, atomically: true, encoding: .utf8)
        try XCTUnwrap(Data(base64Encoded: annotationTIFFBase64)).write(to: annotation)
        let lookup = try AtlasRegionLookup(annotationURL: annotation, structuresURL: structures)

        let descendants = lookup.retrospectiveROIMask(
            for: [
                Brain3DLockedAllenROI(
                    roiSetID: "roi",
                    roiSetName: "Visual",
                    structureID: 385,
                    includeDescendants: true
                )
            ]
        )
        XCTAssertEqual(descendants.includedPixelCount, 1)
        XCTAssertTrue(descendants.contains(x: 1, y: 0))
        XCTAssertFalse(descendants.contains(x: 1, y: 1))
        XCTAssertNotNil(descendants.image())

        let exact = lookup.retrospectiveROIMask(
            for: [
                Brain3DLockedAllenROI(
                    roiSetID: "roi",
                    roiSetName: "CA1",
                    structureID: 382,
                    includeDescendants: false
                )
            ]
        )
        XCTAssertEqual(exact.includedPixelCount, 1)
        XCTAssertTrue(exact.contains(x: 1, y: 1))
        XCTAssertFalse(exact.contains(x: 1, y: 0))
    }

    private func makeContext(locked: Bool) -> Brain3DContext {
        let handoff = Brain3DHistologyHandoff(raw: [
            "usable_for_navigation": .bool(false),
            "roi_sets": .array([
                .object([
                    "roi_set_id": .string("roi-1"),
                    "name": .string("Motor and box"),
                    "allen_structures": .array([
                        .object([
                            "structure_id": .number(500),
                            "include_descendants": .bool(true),
                        ])
                    ]),
                    "asr_boxes": .array([
                        .object([
                            "box_id": .string("box-1"),
                            "minimum": .array([.number(900), .number(200), .number(200)]),
                            "maximum": .array([.number(1_100), .number(600), .number(800)]),
                        ])
                    ]),
                ])
            ]),
        ])
        return Brain3DContext(
            handoff: handoff,
            priorReceipt: Brain3DPriorReceipt(
                handoffId: "handoff-1",
                handoffSha256: String(repeating: "a", count: 64),
                sourceProjectId: "project-1",
                sourceProjectRevision: 1,
                sourceSubjectId: "mouse-1"
            ),
            subjectBinding: Brain3DSubjectBinding(
                state: .exactMatch,
                planSubjectId: "mouse-1",
                datasetSubjectId: "mouse-1",
                datasetFingerprint: "dataset-1"
            ),
            blindReviewLocked: locked,
            reviewPreview: preview()
        )
    }

    private func preview() -> Brain3DReviewPreview {
        Brain3DReviewPreview(
            schemaVersion: 1,
            reviewedTrackSetSha256: String(repeating: "b", count: 64),
            tracks: [
                Brain3DObservedTrackReview(
                    trackId: "track-1",
                    fitDigest: String(repeating: "c", count: 64),
                    endpointA: [1_000, 100, 200],
                    endpointB: [1_000, 700, 800],
                    supportLengthMicrometres: 850,
                    rmseMicrometres: 24,
                    pointCount: 6,
                    distinctSliceCount: 3,
                    leaveOneSectionOutSensitivity: Brain3DLeaveOneSectionOutSensitivity(
                        available: false,
                        reason: "Unavailable for fixture",
                        usableForNavigation: false
                    ),
                    usableForNavigation: false
                )
            ],
            plannedShanks: [
                Brain3DPlannedShankReview(
                    insertionSnapshotId: "insertion-1",
                    planId: "plan-1",
                    shankId: "shank-0",
                    entry: [1_000, 100, 200],
                    tip: [1_000, 700, 800],
                    usableForNavigation: false
                )
            ],
            suggestions: [],
            roiSummaries: [],
            unassignedSourcePointIDs: [],
            usableForNavigation: false
        )
    }

    private func coronalPlacement() -> AtlasSlicePlacement {
        AtlasSlicePlacement(
            sliceToAtlasPlane: .identity,
            pixelSizeMicrons: 10,
            planeSize: PixelSize(width: 100, height: 80),
            atlasOriginIndex: SIMD3<Double>(100, 0, 0),
            atlasUIndex: SIMD3<Double>(0, 0, 100),
            atlasVIndex: SIMD3<Double>(0, 80, 0),
            atlasResolutionMicrons: SIMD3<Double>(10, 10, 10),
            atlasCenterMicrons: SIMD3<Double>(1_000, 400, 500),
            sceneMicronsPerUnit: 1_000,
            isReviewed: true
        )
    }

    private var ontologyJSON: String {
        """
        [
          {"id": 385, "acronym": "VISp", "name": "Primary visual area", "structure_id_path": [385], "rgb_triplet": [8, 133, 140]},
          {"id": 821, "acronym": "VISp2/3", "name": "Primary visual area, layer 2/3", "structure_id_path": [385, 821], "rgb_triplet": [8, 133, 140]},
          {"id": 382, "acronym": "CA1", "name": "Field CA1", "structure_id_path": [382], "rgb_triplet": [126, 208, 75]}
        ]
        """
    }

    private var annotationTIFFBase64: String {
        "SUkqAAgAAAAOAAABBAABAAAAAgAAAAEBBAABAAAAAgAAAAIBAwABAAAAIAAAAAMBAwABAAAAAQAAAAYBAwABAAAAAQAAAA4BAgASAAAAtgAAABEBBAABAAAAAAEAABUBAwABAAAAAQAAABYBBAABAAAAAgAAABcBBAABAAAAEAAAABoBBQABAAAA2AAAABsBBQABAAAA4AAAACgBAwABAAAAAQAAADEBAgAMAAAA6AAAAAAAAAB7InNoYXBlIjogWzIsIDJdfQAAAAAAAAAAAAAAAAAAAAAAAQAAAAEAAAABAAAAAQAAAHRpZmZmaWxlLnB5AAAAAAAAAAAAAAAAAAAAAAA1AwAA2lgzJH4BAAA="
    }
}
