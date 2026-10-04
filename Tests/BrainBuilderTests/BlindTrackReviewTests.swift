import Foundation
import XCTest
@testable import BrainBuilder

final class BlindTrackReviewTests: XCTestCase {
    func testStaleBlindPreviewCannotMutateChangedProject() async {
        let preview = fixturePreview()
        await MainActor.run {
            let store = BrainProjectStore()
            let requested = makeProject()
            var changed = requested
            changed.subjectID = "different-subject"
            store.registrationProject = changed

            XCTAssertFalse(
                store.applyBlindTrackReviewPreview(preview, requestedProject: requested)
            )
            XCTAssertNil(store.registrationProject?.blindTrackReviewPreview)
            XCTAssertEqual(store.registrationProject?.subjectID, "different-subject")

            store.registrationProject = requested
            XCTAssertTrue(
                store.applyBlindTrackReviewPreview(preview, requestedProject: requested)
            )
            XCTAssertEqual(store.registrationProject?.blindTrackReviewPreview, preview)
        }
    }

    func testPreviewBoundaryRejectsBadDigestsDuplicateMembershipAndNonFiniteQC() {
        var preview = fixturePreview()
        XCTAssertTrue(preview.passesRetrospectiveBoundary)
        XCTAssertEqual(preview.asEditableState.groups.count, 2)

        preview.reviewStateSha256 = "not-a-digest"
        XCTAssertFalse(preview.passesRetrospectiveBoundary)

        preview = fixturePreview()
        preview.tracks[1].sourcePointIDs[0] = preview.tracks[0].sourcePointIDs[0]
        XCTAssertFalse(preview.passesRetrospectiveBoundary)

        preview = fixturePreview()
        preview.tracks[0].rmseMicrometres = .infinity
        XCTAssertFalse(preview.passesRetrospectiveBoundary)
    }

    func testSplitMergeAndReassignPreserveExclusiveBlindMembership() throws {
        let preview = fixturePreview()

        let split = try BlindTrackReviewEditor.split(
            preview: preview,
            trackID: "track-a",
            selectedSourcePointIDs: ["a4", "a5", "a6"]
        )
        XCTAssertEqual(split.groups.count, 3)
        assertExclusivePartition(split, expected: Set((1 ... 6).map { "a\($0)" } + ["b1", "b2", "b3", "u1"]))

        let merged = try BlindTrackReviewEditor.merge(
            preview: preview,
            trackIDs: ["track-a", "track-b"]
        )
        XCTAssertEqual(merged.groups.count, 1)
        XCTAssertEqual(merged.groups[0].sourcePointIDs.count, 9)
        assertExclusivePartition(merged, expected: Set((1 ... 6).map { "a\($0)" } + ["b1", "b2", "b3", "u1"]))

        let reassigned = try BlindTrackReviewEditor.reassign(
            preview: preview,
            sourcePointIDs: ["u1"],
            targetTrackID: "track-b"
        )
        XCTAssertEqual(reassigned.groups.first(where: { $0.groupId == "group-b" })?.sourcePointIDs, [
            "b1", "b2", "b3", "u1",
        ])
        XCTAssertTrue(reassigned.unassignedSourcePointIDs.isEmpty)
        assertExclusivePartition(reassigned, expected: Set((1 ... 6).map { "a\($0)" } + ["b1", "b2", "b3", "u1"]))
    }

    func testInvalidEditsFailClosedAndNavigationBoundaryIsLiteralFalse() throws {
        let preview = fixturePreview()
        XCTAssertTrue(preview.passesRetrospectiveBoundary)

        XCTAssertThrowsError(
            try BlindTrackReviewEditor.split(
                preview: preview,
                trackID: "track-a",
                selectedSourcePointIDs: ["a1", "a2"]
            )
        )
        XCTAssertThrowsError(
            try BlindTrackReviewEditor.reassign(
                preview: preview,
                sourcePointIDs: ["a1", "a2", "a3", "a4"],
                targetTrackID: nil
            )
        )

        var navigational = preview
        navigational.usableForNavigation = true
        XCTAssertFalse(navigational.passesRetrospectiveBoundary)
    }

    func testBlindReviewStateRoundTripsWithoutPlanOrROIMembers() throws {
        let state = fixturePreview().asEditableState
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            ["schemaVersion", "groups", "unassignedSourcePointIDs", "usableForNavigation"]
        )
        XCTAssertNil(object["brain3dContext"])
        XCTAssertNil(object["roiSets"])
        XCTAssertEqual(try JSONDecoder().decode(BlindTrackReviewState.self, from: data), state)
    }

    private func fixturePreview() -> BlindTrackReviewPreview {
        BlindTrackReviewPreview(
            schemaVersion: 1,
            reviewedTrackSetSha256: String(repeating: "a", count: 64),
            reviewStateSha256: String(repeating: "b", count: 64),
            tracks: [
                BlindObservedTrackPreview(
                    groupId: "group-a",
                    trackId: "track-a",
                    fitDigest: String(repeating: "c", count: 64),
                    sourcePointIDs: (1 ... 6).map { "a\($0)" },
                    pointCount: 6,
                    distinctSliceCount: 3,
                    supportLengthMicrometres: 1_000,
                    rmseMicrometres: 20,
                    usableForNavigation: false
                ),
                BlindObservedTrackPreview(
                    groupId: "group-b",
                    trackId: "track-b",
                    fitDigest: String(repeating: "d", count: 64),
                    sourcePointIDs: ["b1", "b2", "b3"],
                    pointCount: 3,
                    distinctSliceCount: 2,
                    supportLengthMicrometres: 800,
                    rmseMicrometres: 25,
                    usableForNavigation: false
                ),
            ],
            unassignedSourcePointIDs: ["u1"],
            usableForNavigation: false
        )
    }

    private func makeProject() -> RegistrationProject {
        RegistrationProject(
            id: "blind-review-request",
            subjectID: "ML-2026-0001",
            datasetRootPath: "/tmp/blind-review-request",
            atlas: .allenCCF2020,
            orientation: .coronal,
            pixelSizeMicrons: 1,
            channelMappings: [],
            slices: [],
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            sourceMode: .montageSections
        )
    }

    private func assertExclusivePartition(
        _ state: BlindTrackReviewState,
        expected: Set<String>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let values = state.groups.flatMap(\.sourcePointIDs) + state.unassignedSourcePointIDs
        XCTAssertEqual(values.count, Set(values).count, file: file, line: line)
        XCTAssertEqual(Set(values), expected, file: file, line: line)
        XCTAssertFalse(state.usableForNavigation, file: file, line: line)
    }
}
