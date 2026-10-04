import Foundation
import XCTest
@testable import BrainBuilder

final class Brain3DManualReviewTests: XCTestCase {
    func testStaleBrain3DPreviewCannotCrossHandoffIdentity() async {
        let preview = makePreview()
        await MainActor.run {
            let store = BrainProjectStore()
            let requested = makeProject(context: makeContext(locked: true, preview: nil))
            var changed = requested
            changed.brain3dContext?.priorReceipt.handoffId = "different-handoff"
            store.registrationProject = changed

            XCTAssertFalse(
                store.applyBrain3DReviewPreview(preview, requestedProject: requested)
            )
            XCTAssertNil(store.registrationProject?.brain3dContext?.reviewPreview)
            XCTAssertEqual(
                store.registrationProject?.brain3dContext?.priorReceipt.handoffId,
                "different-handoff"
            )

            store.registrationProject = requested
            XCTAssertTrue(
                store.applyBrain3DReviewPreview(preview, requestedProject: requested)
            )
            XCTAssertEqual(store.registrationProject?.brain3dContext?.reviewPreview, preview)
        }
    }

    func testDatasetFingerprintChangeInvalidatesExactAndAuditedRebindBindings() {
        let originalFingerprint = "dataset-original"
        let changedFingerprint = "dataset-changed"
        var exact = makeContext(locked: false, preview: nil)
        exact.subjectBinding.datasetFingerprint = originalFingerprint

        XCTAssertTrue(exact.isBound(toDatasetFingerprint: originalFingerprint))
        XCTAssertFalse(exact.isBound(toDatasetFingerprint: changedFingerprint))

        let audit = Brain3DSubjectRebindAudit(
            auditId: "audit-1",
            planSubjectId: "mouse-1",
            datasetSubjectId: "legacy-mouse-1",
            datasetFingerprint: originalFingerprint,
            operatorLabel: "reviewer",
            reason: "Verified legacy dataset label",
            confirmedAt: Date(timeIntervalSince1970: 1_700_000_000),
            handoffSha256: exact.priorReceipt.handoffSha256
        )
        exact.subjectBinding = Brain3DSubjectBinding(
            state: .explicitAliasRebind,
            planSubjectId: "mouse-1",
            datasetSubjectId: "legacy-mouse-1",
            datasetFingerprint: originalFingerprint,
            rebindAudit: audit
        )

        XCTAssertTrue(exact.isBound(toDatasetFingerprint: originalFingerprint))
        XCTAssertFalse(exact.isBound(toDatasetFingerprint: changedFingerprint))

        exact.subjectBinding.rebindAudit?.operatorLabel = ""
        XCTAssertFalse(exact.isBound(toDatasetFingerprint: originalFingerprint))
    }

    func testReviewPreviewDecodesRetrospectiveROISummariesAndLOSOFitQC() throws {
        let data = Data(
            #"""
            {
              "schemaVersion": 1,
              "reviewedTrackSetSha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
              "tracks": [{
                "trackId": "track-1",
                "fitDigest": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
                "endpointA": [0, 0, 0],
                "endpointB": [0, 1000, 0],
                "supportLengthMicrometres": 1000,
                "rmseMicrometres": 25,
                "pointCount": 6,
                "distinctSliceCount": 3,
                "leaveOneSectionOutSensitivity": {
                  "available": true,
                  "method": "deterministic-pca-line-refit-leave-one-section-out-v1",
                  "omissionCount": 3,
                  "maximumAxisAngleDegrees": 1.5,
                  "maximumLineSeparationMicrometres": 12,
                  "rmsHeldOutResidualMicrometres": 30,
                  "omissions": [{
                    "omittedSliceId": "slice-a",
                    "retainedPointCount": 4,
                    "heldOutPointCount": 2,
                    "axisAngleDegrees": 1.5,
                    "lineSeparationMicrometres": 12,
                    "heldOutRMSEMicrometres": 30
                  }],
                  "usableForNavigation": false
                },
                "usableForNavigation": false
              }],
              "plannedShanks": [],
              "suggestions": [],
              "roiSummaries": [{
                "roiSetId": "roi-1",
                "name": "Target ROI",
                "scope": "global",
                "insertionSnapshotIds": [],
                "members": [{
                  "memberKey": "box:box-1",
                  "type": "asrBox",
                  "boxId": "box-1",
                  "minimum": [0, 0, 0],
                  "maximum": [100, 100, 100],
                  "plannedSegmentIds": ["insertion-1::shank-0"],
                  "observedTrackIds": ["track-1"],
                  "plannedTraversalLengthMicrometres": 90,
                  "observedTraversalLengthMicrometres": 80
                }],
                "planned": {
                  "segmentIds": ["insertion-1::shank-0"],
                  "traversedMemberKeys": ["box:box-1"],
                  "totalTraversalLengthMicrometres": 90
                },
                "observed": {
                  "segmentIds": ["track-1"],
                  "traversedMemberKeys": ["box:box-1"],
                  "totalTraversalLengthMicrometres": 80
                },
                "intersection": {"traversedMemberKeys": ["box:box-1"]},
                "union": {"traversedMemberKeys": ["box:box-1"]},
                "aggregation": "per-segment interval union; overlapping parent/child and box membership is not double-counted",
                "usableForNavigation": false
              }],
              "unassignedSourcePointIDs": [],
              "usableForNavigation": false
            }
            """#.utf8
        )

        let preview = try JSONDecoder().decode(Brain3DReviewPreview.self, from: data)

        XCTAssertEqual(preview.roiSummaries.first?.name, "Target ROI")
        XCTAssertEqual(
            preview.roiSummaries.first?.observed.totalTraversalLengthMicrometres,
            80
        )
        XCTAssertEqual(
            preview.tracks.first?.leaveOneSectionOutSensitivity.maximumAxisAngleDegrees,
            1.5
        )
        XCTAssertFalse(preview.usableForNavigation)
        XCTAssertFalse(preview.roiSummaries[0].usableForNavigation)
        XCTAssertFalse(
            preview.tracks[0].leaveOneSectionOutSensitivity.usableForNavigation
        )
    }

    func testManualReviewRequiresLockPreviewEveryObservedTrackAndEveryPlannedShank() {
        var context = makeContext(locked: false, preview: nil)
        XCTAssertEqual(
            context.manualReviewBlockers,
            ["Blind registration and track review must be locked before Brain3D comparison."]
        )

        context.blindReviewLocked = true
        XCTAssertEqual(
            context.manualReviewBlockers,
            ["Build the post-lock Brain3D matching review before export."]
        )

        context.reviewPreview = makePreview()
        XCTAssertEqual(
            context.manualReviewBlockers,
            ["Every observed track needs one valid manual disposition with reviewer and reason."]
        )

        context.reviewDispositions = [
            disposition(
                id: "exact",
                state: .exactShank,
                trackID: "track-1",
                insertionID: "insertion-1",
                shankID: "shank-0"
            )
        ]
        XCTAssertEqual(
            context.manualReviewBlockers,
            ["Every planned physical shank needs an exact, ambiguous, or not-observed disposition."]
        )

        context.reviewDispositions.append(
            disposition(
                id: "missing",
                state: .plannedNotObserved,
                insertionID: "insertion-1",
                shankID: "shank-1"
            )
        )
        XCTAssertTrue(context.manualReviewBlockers.isEmpty)
    }

    func testInsertionAmbiguityCoversPhysicalShanksAndRejectsConflictingMissingState() {
        var context = makeContext(locked: true, preview: makePreview())
        context.reviewDispositions = [
            disposition(
                id: "ambiguous",
                state: .insertionLevelAmbiguous,
                trackID: "track-1",
                insertionID: "insertion-1"
            )
        ]
        XCTAssertTrue(context.manualReviewBlockers.isEmpty)

        context.reviewDispositions.append(
            disposition(
                id: "conflict",
                state: .plannedNotObserved,
                insertionID: "insertion-1",
                shankID: "shank-0"
            )
        )
        XCTAssertEqual(
            context.manualReviewBlockers,
            ["Brain3D review contains conflicting planned-shank dispositions."]
        )
    }

    private func makeContext(
        locked: Bool,
        preview: Brain3DReviewPreview?
    ) -> Brain3DContext {
        Brain3DContext(
            handoff: Brain3DHistologyHandoff(raw: [:]),
            priorReceipt: Brain3DPriorReceipt(
                handoffId: "handoff",
                handoffSha256: String(repeating: "a", count: 64),
                sourceProjectId: UUID().uuidString,
                sourceProjectRevision: 1,
                sourceSubjectId: "mouse-1"
            ),
            subjectBinding: Brain3DSubjectBinding(
                state: .exactMatch,
                planSubjectId: "mouse-1",
                datasetSubjectId: "mouse-1",
                datasetFingerprint: "sha256:dataset"
            ),
            blindReviewLocked: locked,
            reviewPreview: preview
        )
    }

    private func makeProject(context: Brain3DContext) -> RegistrationProject {
        RegistrationProject(
            id: "brain3d-review-request",
            subjectID: "mouse-1",
            datasetRootPath: "/tmp/brain3d-review-request",
            atlas: .allenCCF2020,
            orientation: .coronal,
            pixelSizeMicrons: 1,
            channelMappings: [],
            slices: [],
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            sourceMode: .montageSections,
            brain3dContext: context,
            blindReviewLocked: true
        )
    }

    private func makePreview() -> Brain3DReviewPreview {
        Brain3DReviewPreview(
            schemaVersion: 1,
            reviewedTrackSetSha256: String(repeating: "b", count: 64),
            tracks: [
                Brain3DObservedTrackReview(
                    trackId: "track-1",
                    fitDigest: String(repeating: "c", count: 64),
                    endpointA: [100, 200, 300],
                    endpointB: [110, 1_200, 320],
                    supportLengthMicrometres: 1_000,
                    rmseMicrometres: 25,
                    pointCount: 5,
                    distinctSliceCount: 3,
                    leaveOneSectionOutSensitivity: Brain3DLeaveOneSectionOutSensitivity(
                        available: true,
                        method: "deterministic-pca-line-refit-leave-one-section-out-v1",
                        omissionCount: 3,
                        maximumAxisAngleDegrees: 0.5,
                        maximumLineSeparationMicrometres: 10,
                        rmsHeldOutResidualMicrometres: 20,
                        omissions: [],
                        usableForNavigation: false
                    ),
                    usableForNavigation: false
                )
            ],
            plannedShanks: [
                plannedShank("shank-0"),
                plannedShank("shank-1"),
            ],
            suggestions: [],
            roiSummaries: [],
            unassignedSourcePointIDs: [],
            usableForNavigation: false
        )
    }

    private func plannedShank(_ shankID: String) -> Brain3DPlannedShankReview {
        Brain3DPlannedShankReview(
            insertionSnapshotId: "insertion-1",
            planId: "plan-1",
            shankId: shankID,
            entry: [100, 200, 300],
            tip: [110, 1_200, 320],
            usableForNavigation: false
        )
    }

    private func disposition(
        id: String,
        state: Brain3DTrackDisposition.State,
        trackID: String? = nil,
        insertionID: String? = nil,
        shankID: String? = nil
    ) -> Brain3DTrackDisposition {
        Brain3DTrackDisposition(
            id: id,
            state: state,
            trackId: trackID,
            insertionSnapshotId: insertionID,
            shankId: shankID,
            reviewerLabel: "reviewer-a",
            reason: "Manual retrospective evidence review",
            confirmedAt: Date(timeIntervalSince1970: 1_786_000_000)
        )
    }
}
