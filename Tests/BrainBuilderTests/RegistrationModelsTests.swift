import AppKit
import SwiftUI
import XCTest
@testable import BrainBuilder

final class RegistrationModelsTests: XCTestCase {
    func testCanonicalOrientationRequiresCompleteSelectionMaskProvenanceWhenPresent() throws {
        var project = makeVerifiedOrientationProject(
            slices: [
                makeVerifiedOrientationSlice(id: "slice-a", groupID: "XY01", rotationDegrees: 0, atlasAPMicrons: 4_200),
                makeVerifiedOrientationSlice(id: "slice-b", groupID: "XY01", rotationDegrees: 0, atlasAPMicrons: 4_400)
            ],
            groupOrientations: ["XY01": 0]
        )
        project.provenance?.selectionMaskHashes = ["slice-a": "mask-a"]
        XCTAssertFalse(project.hasCompleteCanonicalSectionOrientation)
        project.provenance?.selectionMaskHashes?["slice-b"] = "mask-b"
        XCTAssertTrue(project.hasCompleteCanonicalSectionOrientation)
        let provenance = try XCTUnwrap(project.provenance)
        let decoded = try JSONDecoder().decode(
            RegistrationProjectProvenance.self, from: JSONEncoder().encode(provenance)
        )
        XCTAssertEqual(decoded.selectionMaskHashes, provenance.selectionMaskHashes)
    }

    func testSchemaOneSingleProbeTrackMigratesLosslesslyToSchemaTwoCandidateArray() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("schema-one-track-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let legacyTrack = makeProbeTrack(candidateID: "legacy-candidate")
        var slice = makeSlice(status: .poseEstimated, transforms: [.posePrior(makePose())])
        slice.probeTrack = legacyTrack
        slice.probeTrackCandidates = nil
        var project = makeProject(slices: [slice])
        project.schemaVersion = 1
        let projectURL = folder.appendingPathComponent("registration-project.json")

        let service = RegistrationWorkerService()
        try service.write(project, to: projectURL)
        let migrated = try service.readProject(at: projectURL)

        XCTAssertEqual(migrated.schemaVersion, 2)
        XCTAssertEqual(migrated.slices[0].probeTrack, legacyTrack)
        XCTAssertEqual(migrated.slices[0].probeTrackCandidates, [legacyTrack])
    }

    func testDecodedProjectRejectsMoreThanThirtyTwoProbeTrackCandidates() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("candidate-overflow-decode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var slice = makeSlice(status: .poseEstimated, transforms: [.posePrior(makePose())])
        slice.probeTrackCandidates = (0...32).map { makeProbeTrack(candidateID: "candidate-\($0)") }
        let project = makeProject(slices: [slice])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let projectURL = folder.appendingPathComponent("tampered-project.json")
        try encoder.encode(project).write(to: projectURL)

        XCTAssertThrowsError(try RegistrationWorkerService().readProject(at: projectURL)) { error in
            guard case RegistrationWorkerError.resultReadFailed(let detail) = error else {
                return XCTFail("Expected resultReadFailed, got \(error)")
            }
            XCTAssertTrue(detail.contains("32"), detail)
        }
    }

    func testProjectWriteRejectsMoreThanThirtyTwoProbeTrackCandidates() throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("candidate-overflow-write-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: projectURL) }
        var slice = makeSlice(status: .poseEstimated, transforms: [.posePrior(makePose())])
        slice.probeTrackCandidates = (0...32).map { makeProbeTrack(candidateID: "candidate-\($0)") }
        let project = makeProject(slices: [slice])

        XCTAssertThrowsError(try RegistrationWorkerService().write(project, to: projectURL)) { error in
            XCTAssertEqual(
                error as? RegistrationProjectValidationError,
                .tooManyProbeTrackCandidates(sliceID: slice.id, count: 33, maximum: 32)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.path))
    }

    func testRegistrationWorkerProgressDecodesPythonSidecarContract() throws {
        let data = Data(
            #"{"schemaVersion":1,"command":"register-project","stage":"registeringSlices","completed":7,"total":24,"failed":1,"sliceID":"XY02-00007","sliceTitle":"XY02 00007","message":"Finished XY02 00007 (7 of 24); 1 failed.","updatedAt":"2026-07-21T16:02:03.123456+00:00"}"#.utf8
        )

        let progress = try RegistrationWorkerService().decodeProgress(data)

        XCTAssertEqual(progress.stage, .registeringSlices)
        XCTAssertEqual(progress.completed, 7)
        XCTAssertEqual(progress.total, 24)
        XCTAssertEqual(progress.failed, 1)
        XCTAssertEqual(progress.sliceID, "XY02-00007")
        XCTAssertEqual(progress.sliceTitle, "XY02 00007")
        XCTAssertEqual(try XCTUnwrap(progress.fractionCompleted), 7.0 / 24.0, accuracy: 1e-12)
    }

    func testRegistrationWorkerProgressRejectsImpossibleCounts() throws {
        let data = Data(
            #"{"schemaVersion":1,"command":"register-project","stage":"registeringSlices","completed":25,"total":24,"failed":0,"sliceID":null,"sliceTitle":null,"message":"invalid","updatedAt":"2026-07-21T16:02:03+00:00"}"#.utf8
        )

        XCTAssertThrowsError(try RegistrationWorkerService().decodeProgress(data))
    }

    func testRegistrationWorkerProgressNamesOnlyFinalProjectCompletionAsRegistrationComplete() {
        let finalRegistration = RegistrationWorkerProgress(
            command: RegistrationWorkerCommand.registerProject.rawValue,
            stage: .completed,
            completed: 24,
            total: 24,
            message: "Finished registering 24 sections."
        )
        let preparation = RegistrationWorkerProgress(
            command: RegistrationWorkerCommand.prepare.rawValue,
            stage: .completed,
            completed: 24,
            total: 24,
            message: "Prepared 24 sections."
        )

        XCTAssertEqual(finalRegistration.displayTitle, "Registration complete")
        XCTAssertEqual(preparation.displayTitle, "Stage complete")
    }

    func testCancelRegistrationWorkerTransitionsOnceAndIsIdempotent() async {
        await MainActor.run {
            let store = BrainProjectStore()
            store.status = "Registering sections"
            store.installRegistrationWorkerStateForTesting(isRunning: true)

            store.cancelRegistrationWorker()

            XCTAssertTrue(store.isRunningRegistrationWorker)
            XCTAssertTrue(store.isCancelingRegistrationWorker)
            XCTAssertEqual(store.status, "Canceling registration...")

            let statusAfterFirstRequest = store.status
            store.cancelRegistrationWorker()

            XCTAssertTrue(store.isCancelingRegistrationWorker)
            XCTAssertEqual(store.status, statusAfterFirstRequest)
        }
    }

    func testRegistrationWorkerCancellationForceStopsTermIgnoringProcessWithinDeadline() throws {
        let process = Process()
        let readinessPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; printf ready; exec /bin/sleep 60"]
        process.standardOutput = readinessPipe
        try process.run()
        defer {
            if process.isRunning {
                _ = RegistrationWorkerService.terminateProcess(
                    process,
                    policy: RegistrationWorkerTerminationPolicy(
                        gracefulTimeout: 0,
                        forcedTimeout: 0.5,
                        pollInterval: 0.005
                    )
                )
            }
        }

        let readiness = try XCTUnwrap(try readinessPipe.fileHandleForReading.read(upToCount: 5))
        XCTAssertEqual(String(decoding: readiness, as: UTF8.self), "ready")

        let startedAt = Date()
        let stopped = RegistrationWorkerService.terminateProcess(
            process,
            policy: RegistrationWorkerTerminationPolicy(
                gracefulTimeout: 0.1,
                forcedTimeout: 0.5,
                pollInterval: 0.005
            )
        )

        XCTAssertTrue(stopped)
        XCTAssertFalse(process.isRunning)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
    }

    func testRegistrationWorkerSidecarCleanupRemovesProgressAndResultFiles() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("registration-sidecar-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let resultURL = folder.appendingPathComponent(".worker-result.json")
        let progressURL = folder.appendingPathComponent(".worker-progress.json")
        try Data("result".utf8).write(to: resultURL)
        try Data("progress".utf8).write(to: progressURL)

        RegistrationWorkerService.removeWorkerSidecars([resultURL, progressURL])

        XCTAssertFalse(FileManager.default.fileExists(atPath: resultURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: progressURL.path))
    }

    func testRebuildVolumeFailsClosedWhileRegistrationIsRunningOrCanceling() async {
        let store = await MainActor.run {
            let store = BrainProjectStore()
            store.installRegistrationWorkerStateForTesting(isRunning: true)
            return store
        }

        await store.rebuildVolume()
        await MainActor.run {
            XCTAssertEqual(store.status, "Cancel registration before rebuilding the 3D stack")
            XCTAssertFalse(store.isBuildingVolume)
            store.installRegistrationWorkerStateForTesting(isRunning: true, isCanceling: true)
        }

        await store.rebuildVolume()
        await MainActor.run {
            XCTAssertEqual(
                store.status,
                "Wait for registration cancellation to finish before rebuilding the 3D stack"
            )
            XCTAssertFalse(store.isBuildingVolume)
        }
    }

    func testScanningAnotherFolderClearsExportActivity() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-export-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = await MainActor.run {
            let store = BrainProjectStore()
            store.isExporting = true
            return store
        }

        await store.scanFolder(folder)

        await MainActor.run {
            XCTAssertFalse(store.isExporting)
            XCTAssertTrue(store.status.hasPrefix("Scan failed:"))
        }
    }

    func testReviewedStackStateSanitizesHistoryAndRejectsExcludingEverySlice() throws {
        var archived = makeSlice(
            status: .accepted,
            transforms: [.posePrior(makePose())],
            id: "slice-b"
        )
        archived.reviewNotes = "Keep this review"
        let state = ReviewedStackState(
            datasetRootPath: "/tmp/data",
            sourceMode: .montageSections,
            datasetFingerprint: "fingerprint",
            excludedSliceIDs: ["slice-b", "missing", "slice-b"],
            exclusionHistory: ["missing", "slice-b", "slice-b"],
            archivedRegistrationSlices: [archived, archived]
        )

        let sanitized = try XCTUnwrap(
            state.sanitized(validSliceIDs: ["slice-a", "slice-b", "slice-c"])
        )

        XCTAssertEqual(sanitized.excludedSliceIDs, ["slice-b"])
        XCTAssertEqual(sanitized.exclusionHistory, ["slice-b"])
        XCTAssertEqual(sanitized.archivedRegistrationSlices, [archived])

        var invalid = state
        invalid.excludedSliceIDs = ["slice-a", "slice-b"]
        XCTAssertNil(invalid.sanitized(validSliceIDs: ["slice-a", "slice-b"]))
    }

    func testReviewedStackArchiveRoundTripAndMergePreserveRegistrationWork() throws {
        var archived = makeSlice(
            status: .accepted,
            transforms: [.posePrior(makePose()), makeAffineTransform()],
            id: "slice-b"
        )
        archived.reviewNotes = "Manually accepted after review"
        archived.qc.majorRegionIoU = 0.84
        archived.transformChain.transforms[0].createdAt = Date(timeIntervalSince1970: 1)
        let state = ReviewedStackState(
            datasetRootPath: "/tmp/data",
            sourceMode: .montageSections,
            datasetFingerprint: "fingerprint",
            excludedSliceIDs: ["slice-b"],
            exclusionHistory: ["slice-b"],
            archivedRegistrationSlices: [archived]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(
            ReviewedStackState.self,
            from: encoder.encode(state)
        )
        let currentProject = makeProject(
            slices: [
                makeSlice(
                    status: .prepared,
                    transforms: [.posePrior(makePose())],
                    id: "slice-a"
                )
            ]
        )
        let merged = try XCTUnwrap(decoded.mergingArchivedSlices(into: currentProject))

        XCTAssertEqual(merged.slices.map(\.id), ["slice-a", "slice-b"])
        XCTAssertEqual(merged.slices.last, archived)
        XCTAssertEqual(merged.slices.last?.reviewNotes, "Manually accepted after review")
        XCTAssertEqual(merged.slices.last?.qc.majorRegionIoU, 0.84)
    }

    func testVolumeSliceNavigationMovesPredictablyAndStopsAtBounds() async {
        await MainActor.run {
            let store = makeNavigationStore(sliceIDs: ["slice-a", "slice-b", "slice-c"])

            XCTAssertEqual(store.selectedVolumeSliceIndex, 0)
            XCTAssertEqual(store.selectedVolumeSlice?.id, "slice-a")

            store.moveSelectedVolumeSlice(by: -1)
            XCTAssertEqual(store.selectedVolumeSlice?.id, "slice-a")

            store.moveSelectedVolumeSlice(by: 1)
            XCTAssertEqual(store.selectedVolumeSliceIndex, 1)
            XCTAssertEqual(store.selectedVolumeSlice?.id, "slice-b")

            store.moveSelectedVolumeSlice(by: 1)
            store.moveSelectedVolumeSlice(by: 1)
            XCTAssertEqual(store.selectedVolumeSliceIndex, 2)
            XCTAssertEqual(store.selectedVolumeSlice?.id, "slice-c")
        }
    }

    func testVolumeSliceSelectionRejectsUnknownIDsAndExclusionStateTracksAvailability() async {
        await MainActor.run {
            let store = makeNavigationStore(sliceIDs: ["slice-a", "slice-b"])

            store.selectVolumeSlice(id: "missing")
            XCTAssertNil(store.selectedSliceID)
            XCTAssertTrue(store.canExcludeVolumeSlice)

            store.selectVolumeSlice(id: "slice-b")
            XCTAssertEqual(store.selectedSliceID, "slice-b")

            store.isRunningRegistrationWorker = true
            XCTAssertFalse(store.canExcludeVolumeSlice)

            store.isRunningRegistrationWorker = false
            store.isBuildingVolume = true
            XCTAssertFalse(store.canExcludeVolumeSlice)

            store.isBuildingVolume = false
            store.excludedSliceIDs = ["slice-a"]
            XCTAssertTrue(store.canRestoreExcludedVolumeSlices)

            store.isExporting = true
            XCTAssertFalse(store.canRestoreExcludedVolumeSlices)

            store.isExporting = false
            store.volume?.slices.removeLast()
            XCTAssertFalse(store.canExcludeVolumeSlice)
        }
    }

    func testChangingSourceModeToMontageSynchronouslyWithholdsOldVolume() async {
        await MainActor.run {
            let store = makeNavigationStore(sliceIDs: ["slice-a", "slice-b"])
            store.sourceMode = .numberedOverlays
            XCTAssertNotNil(store.volume)

            store.changeSourceMode(to: .montageSections)

            XCTAssertNil(store.volume)
            XCTAssertEqual(store.sectionOrientationState, .pending)
        }
    }

    func testWorkspaceStatusCategoryDistinguishesFeedbackKinds() {
        XCTAssertEqual(
            WorkspaceStatusCategory(message: "Preparing registration project...", isBusy: true),
            .working
        )
        XCTAssertEqual(
            WorkspaceStatusCategory(message: "Accepted Slice 001 for atlas export", isBusy: false),
            .success
        )
        XCTAssertEqual(
            WorkspaceStatusCategory(message: "Atlas export blocked: review slices", isBusy: false),
            .warning
        )
        XCTAssertEqual(
            WorkspaceStatusCategory(message: "Registration failed: worker exited", isBusy: false),
            .failure
        )
        XCTAssertEqual(
            WorkspaceStatusCategory(message: "Rejected Slice 001 · reviewing Slice 002 next", isBusy: false),
            .failure
        )
        XCTAssertEqual(
            WorkspaceStatusCategory(message: "Review complete · all sections accepted", isBusy: false),
            .success
        )
        XCTAssertEqual(
            WorkspaceStatusCategory(message: "Selected Slice 001", isBusy: false),
            .neutral
        )
    }

    func testPlausibleTissueComponentAcceptsCoronalSectionShape() {
        let component = TissueComponent(
            bounds: CGRect(x: 260, y: 180, width: 380, height: 250),
            area: 72_000
        )

        XCTAssertTrue(component.isPlausibleCoronalSection(in: PixelSize(width: 1400, height: 1050)))
    }

    func testPlausibleTissueComponentRejectsThinEdgeStrip() {
        let component = TissueComponent(
            bounds: CGRect(x: 0, y: 130, width: 130, height: 430),
            area: 22_000
        )

        XCTAssertFalse(component.isPlausibleCoronalSection(in: PixelSize(width: 1400, height: 1050)))
    }

    func testPlausibleTissueComponentRejectsVerticalFragmentAwayFromEdge() {
        let component = TissueComponent(
            bounds: CGRect(x: 520, y: 180, width: 190, height: 310),
            area: 38_000
        )

        XCTAssertFalse(component.isPlausibleCoronalSection(in: PixelSize(width: 1400, height: 1050)))
    }

    func testPlausibleTissueComponentRejectsSparseNoisePatch() {
        let component = TissueComponent(
            bounds: CGRect(x: 340, y: 210, width: 330, height: 250),
            area: 9_000
        )

        XCTAssertFalse(component.isPlausibleCoronalSection(in: PixelSize(width: 1400, height: 1050)))
    }

    func testSmallSectionOutlierFilterRejectsTinyFragmentsAmongRealSections() {
        let components = [
            TissueComponent(bounds: CGRect(x: 40, y: 80, width: 720, height: 380), area: 195_000),
            TissueComponent(bounds: CGRect(x: 80, y: 520, width: 700, height: 390), area: 190_000),
            TissueComponent(bounds: CGRect(x: 900, y: 760, width: 176, height: 156), area: 15_000)
        ]

        let filtered = ImageProcessingService.removeSmallSectionOutliers(components)

        XCTAssertEqual(filtered.map(\.area), [195_000, 190_000])
    }

    func testSectionReviewFlagsCallOutSideClippedLowFillComponents() {
        let signal = makeSignal(
            area: 2_000,
            bounds: CGRect(x: 0, y: 12, width: 100, height: 80),
            foregroundConfidence: 0.92
        )

        XCTAssertEqual(signal.sectionReviewFlags, ["Side edge", "Low fill"])
    }

    func testSectionReviewFlagsStayEmptyForCenteredDenseComponents() {
        let signal = makeSignal(
            area: 7_200,
            bounds: CGRect(x: 20, y: 12, width: 100, height: 80),
            foregroundConfidence: 0.92
        )

        XCTAssertTrue(signal.sectionReviewFlags.isEmpty)
    }

    func testAffineInverseRoundTripsPoints() throws {
        let transform = AffineTransform2D(
            m00: 1.2,
            m01: -0.15,
            m10: 0.08,
            m11: 0.93,
            tx: 42,
            ty: -17
        )
        let inverse = try XCTUnwrap(transform.inverted())
        let point = RegistrationPoint(x: 128.5, y: 77.25)

        let roundTrip = inverse.applying(to: transform.applying(to: point))

        XCTAssertEqual(roundTrip.x, point.x, accuracy: 1e-9)
        XCTAssertEqual(roundTrip.y, point.y, accuracy: 1e-9)
    }

    func testAffineConcatenationAppliesTransformsInOrder() {
        let first = AffineTransform2D(m00: 1, m01: 0, m10: 0, m11: 1, tx: 10, ty: 3)
        let second = AffineTransform2D(m00: 2, m01: 0, m10: 0, m11: 2, tx: -5, ty: 7)
        let point = RegistrationPoint(x: 4, y: 9)

        let sequential = second.applying(to: first.applying(to: point))
        let composed = first.concatenating(second).applying(to: point)

        XCTAssertEqual(composed.x, sequential.x, accuracy: 1e-9)
        XCTAssertEqual(composed.y, sequential.y, accuracy: 1e-9)
    }

    func testPosePriorDoesNotCountAsQuantitativeTransform() {
        let pose = SlicePose.estimated(apMicrons: 4_200, confidence: 0.4, provenance: "unit")
        let chain = TransformChain(direction: .atlasToSlice, transforms: [.posePrior(pose)])

        XCTAssertFalse(chain.hasQuantitativeTransform)
    }

    func testRegistrationReviewProgressAndNextPendingSelectionWrapPredictably() {
        var project = makeProject(
            slices: [
                makeSlice(status: .accepted, transforms: [], id: "slice-a"),
                makeSlice(status: .affineDone, transforms: [], id: "slice-b"),
                makeSlice(status: .failed, transforms: [], id: "slice-c"),
                makeSlice(status: .needsReview, transforms: [], id: "slice-d")
            ]
        )

        XCTAssertEqual(project.reviewedSlices.map(\.id), ["slice-a", "slice-c"])
        XCTAssertEqual(project.pendingReviewSlices.map(\.id), ["slice-b", "slice-d"])
        XCTAssertEqual(project.nextPendingReviewSliceID(after: "slice-a"), "slice-b")
        XCTAssertEqual(project.nextPendingReviewSliceID(after: "slice-b"), "slice-d")
        XCTAssertEqual(project.nextPendingReviewSliceID(after: "slice-d"), "slice-b")
        XCTAssertEqual(project.nextPendingReviewSliceID(after: "missing"), "slice-b")

        project.slices[1].status = .accepted
        project.slices[3].status = .failed
        XCTAssertNil(project.nextPendingReviewSliceID(after: "slice-a"))
    }

    func testRegistrationCompletionSummaryCountsPercentilesAndConsistentGroupOrientations() throws {
        let statuses: [SliceRegistrationStatus] = [
            .affineDone,
            .affineDone,
            .needsReview,
            .accepted,
            .failed
        ]
        let values = [0.2, 0.4, 0.6, 0.8, 1.0]
        var slices = statuses.enumerated().map { index, status in
            makeSlice(status: status, transforms: [], id: "slice-\(index)")
        }
        let rotations = [0.0, 360.0, 180.0, -180.0, 540.0]
        for index in slices.indices {
            slices[index].groupID = index < 2 ? "XY01" : "XY02"
            slices[index].qc.majorRegionIoU = values[index]
            slices[index].pose?.rotationDegrees = rotations[index]
        }

        let summary = try XCTUnwrap(
            RegistrationCompletionSummary(project: makeProject(slices: slices))
        )

        XCTAssertEqual(summary.statusCounts.affineDone, 2)
        XCTAssertEqual(summary.statusCounts.needsReview, 1)
        XCTAssertEqual(summary.statusCounts.accepted, 1)
        XCTAssertEqual(summary.statusCounts.failed, 1)
        XCTAssertEqual(summary.statusCounts.total, 5)
        XCTAssertEqual(summary.measuredMajorRegionIoUCount, 5)
        XCTAssertEqual(summary.missingMajorRegionIoUCount, 0)
        XCTAssertEqual(summary.invalidMajorRegionIoUCount, 0)
        XCTAssertEqual(try XCTUnwrap(summary.medianMajorRegionIoU), 0.6, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(summary.p10MajorRegionIoU), 0.28, accuracy: 1e-12)
        XCTAssertEqual(summary.groupOrientations.map(\.groupID), ["XY01", "XY02"])

        guard case .consistent(let firstOrientation) = summary.groupOrientations[0].state,
              case .consistent(let secondOrientation) = summary.groupOrientations[1].state else {
            return XCTFail("Expected both montage groups to have a consistent orientation")
        }
        XCTAssertEqual(firstOrientation.title, "0°")
        XCTAssertEqual(secondOrientation.title, "180°")
    }

    func testRegistrationCompletionSummaryMakesMixedMissingAndInvalidDataExplicit() throws {
        var slices = (0..<5).map { index in
            makeSlice(status: .needsReview, transforms: [], id: "slice-\(index)")
        }
        slices[0].groupID = "XY01"
        slices[1].groupID = "XY01"
        slices[2].groupID = "XY01"
        slices[0].pose?.rotationDegrees = 0
        slices[1].pose?.rotationDegrees = 180
        slices[2].pose = nil
        slices[3].groupID = "XY02"
        slices[4].groupID = "XY02"
        slices[3].pose?.rotationDegrees = 0
        slices[4].pose = nil
        slices[0].qc.majorRegionIoU = 0.5
        slices[1].qc.majorRegionIoU = 1.2
        slices[2].qc.majorRegionIoU = .nan

        let summary = try XCTUnwrap(
            RegistrationCompletionSummary(project: makeProject(slices: slices))
        )

        XCTAssertEqual(summary.measuredMajorRegionIoUCount, 1)
        XCTAssertEqual(summary.invalidMajorRegionIoUCount, 2)
        XCTAssertEqual(summary.missingMajorRegionIoUCount, 2)
        XCTAssertEqual(summary.medianMajorRegionIoU, 0.5)
        XCTAssertEqual(summary.p10MajorRegionIoU, 0.5)

        guard case .inconsistent(let orientations, let missingCount, let total) = summary.groupOrientations[0].state else {
            return XCTFail("Expected XY01 to report inconsistent orientations")
        }
        XCTAssertEqual(orientations.map(\.title), ["0°", "180°"])
        XCTAssertEqual(missingCount, 1)
        XCTAssertEqual(total, 3)
        XCTAssertTrue(summary.groupOrientations[0].state.title.contains("Inconsistent"))

        guard case .incomplete(let orientation, let orientedCount, let total) = summary.groupOrientations[1].state else {
            return XCTFail("Expected XY02 to report an incomplete orientation")
        }
        XCTAssertEqual(orientation?.title, "0°")
        XCTAssertEqual(orientedCount, 1)
        XCTAssertEqual(total, 2)
        XCTAssertTrue(summary.groupOrientations[1].state.title.contains("Incomplete"))
    }

    func testRegistrationCompletionSummaryTreatsRasterFlipsAsOrientationDifferences() throws {
        var slices = [
            makeSlice(status: .affineDone, transforms: [], id: "slice-a"),
            makeSlice(status: .affineDone, transforms: [], id: "slice-b")
        ]
        slices[1].pose?.flipVertical = true

        let summary = try XCTUnwrap(
            RegistrationCompletionSummary(project: makeProject(slices: slices))
        )

        guard case .inconsistent(let orientations, let missingCount, let total) = summary.groupOrientations[0].state else {
            return XCTFail("Expected a raster flip mismatch to be reported as inconsistent")
        }
        XCTAssertEqual(orientations.map(\.title), ["0°", "0° · flip V"])
        XCTAssertEqual(missingCount, 0)
        XCTAssertEqual(total, 2)
    }

    func testRegistrationCompletionSummaryRendersCompactlyAtWorkbenchWidth() async throws {
        var slices = (0..<24).map { index in
            makeSlice(
                status: index < 18 ? .affineDone : .needsReview,
                transforms: [],
                id: "slice-\(index)"
            )
        }
        for index in slices.indices {
            let group: String
            switch index {
            case 0..<9:
                group = "XY01"
            case 9..<12:
                group = "XY02"
            case 12..<18:
                group = "XY03"
            default:
                group = "XY04"
            }
            slices[index].groupID = group
            slices[index].pose?.rotationDegrees = index < 12 ? 0 : 180
            slices[index].qc.majorRegionIoU = 0.70 + Double(index) * 0.01
        }
        let summary = try XCTUnwrap(
            RegistrationCompletionSummary(project: makeProject(slices: slices))
        )

        try await MainActor.run {
            let content = RegistrationCompletionSummaryView(summary: summary)
                .frame(width: 680)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)

            XCTAssertGreaterThanOrEqual(image.size.width, 680)
            XCTAssertLessThan(image.size.height, 260)

            if let snapshotPath = ProcessInfo.processInfo.environment["BRAINBUILDER_QC_SNAPSHOT_PATH"] {
                var rect = NSRect(origin: .zero, size: image.size)
                let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
                let representation = NSBitmapImageRep(cgImage: cgImage)
                let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: snapshotPath), options: .atomic)
            }
        }
    }

    func testCompletedAutoRegistrationSummaryRequiresMatchingFinalProjectEvidence() throws {
        var affineDone = makeVerifiedOrientationSlice(
            id: "slice-a",
            groupID: "XY01",
            rotationDegrees: 0,
            atlasAPMicrons: 4_200
        )
        affineDone.status = .affineDone
        var failed = makeVerifiedOrientationSlice(
            id: "slice-b",
            groupID: "XY03",
            rotationDegrees: 180,
            atlasAPMicrons: 4_400
        )
        failed.status = .failed
        var project = makeVerifiedOrientationProject(
            slices: [
                affineDone,
                failed
            ],
            groupOrientations: ["XY01": 0, "XY03": 180]
        )
        let completedProject = project
        var result = RegistrationWorkerResult(
            command: RegistrationWorkerCommand.registerProject.rawValue,
            stage: .ok,
            projectID: project.id,
            outputPath: nil,
            messages: ["Registered 2 sections."],
            project: completedProject,
            slice: nil,
            export: nil
        )
        let progress = RegistrationWorkerProgress(
            command: RegistrationWorkerCommand.registerProject.rawValue,
            stage: .completed,
            completed: 2,
            total: 2,
            failed: 1,
            message: "Registered 2 sections."
        )

        XCTAssertNotNil(
            BrainProjectStore.completedAutoRegistrationSummary(
                progress: progress,
                result: result,
                project: project
            )
        )

        project.slices[0].status = .accepted
        result.project = project
        let reviewedSummary = try XCTUnwrap(
            BrainProjectStore.completedAutoRegistrationSummary(
                progress: progress,
                result: result,
                project: project
            )
        )
        XCTAssertEqual(reviewedSummary.statusCounts.accepted, 1)

        var preparationProgress = progress
        preparationProgress.command = RegistrationWorkerCommand.prepare.rawValue
        XCTAssertNil(
            BrainProjectStore.completedAutoRegistrationSummary(
                progress: preparationProgress,
                result: result,
                project: project
            )
        )

        var mismatchedProject = project
        mismatchedProject.slices[0].reviewNotes = "Changed after the worker result was published"
        XCTAssertTrue(mismatchedProject.hasCompleteCanonicalSectionOrientation)
        XCTAssertNil(
            BrainProjectStore.completedAutoRegistrationSummary(
                progress: progress,
                result: result,
                project: mismatchedProject
            )
        )

        var mismatchedFailureCount = progress
        mismatchedFailureCount.failed = 0
        XCTAssertNil(
            BrainProjectStore.completedAutoRegistrationSummary(
                progress: mismatchedFailureCount,
                result: result,
                project: project
            )
        )

        var intermediateProject = project
        intermediateProject.slices[0].status = .poseEstimated
        XCTAssertTrue(intermediateProject.hasCompleteCanonicalSectionOrientation)
        XCTAssertNil(
            BrainProjectStore.completedAutoRegistrationSummary(
                progress: progress,
                result: result,
                project: intermediateProject
            )
        )
    }

    func testAcceptanceReadinessRequiresWorkerPoseTransformAndMatchingArtifacts() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrainBuilderReadinessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let transformURL = folder.appendingPathComponent("affine.tfm")
        let annotationURL = folder.appendingPathComponent("annotation.png")
        let boundaryURL = folder.appendingPathComponent("boundary.png")
        try writeInsightAffine(to: transformURL)
        try writeTestImage(to: annotationURL)
        try writeTestImage(to: boundaryURL)

        var affine = makeAffineTransform()
        affine.transformParametersPath = transformURL.path
        var slice = makeSlice(
            status: .affineDone,
            transforms: [makeWorkerPoseTransform(), affine]
        )
        slice.artifacts = makeAcceptanceArtifacts(
            transformURL: transformURL,
            annotationURL: annotationURL,
            boundaryURL: boundaryURL
        )

        XCTAssertTrue(slice.isReadyForAcceptance)

        slice.transformChain.transforms.removeAll { $0.kind == .pose }
        XCTAssertFalse(slice.isReadyForAcceptance)
    }

    func testRegistrationDecisionsAdvanceAndUndoRecordAndSelection() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrainBuilderDecisionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let transformURL = folder.appendingPathComponent("affine.tfm")
        let annotationURL = folder.appendingPathComponent("annotation.png")
        let boundaryURL = folder.appendingPathComponent("boundary.png")
        try writeInsightAffine(to: transformURL)
        try writeTestImage(to: annotationURL)
        try writeTestImage(to: boundaryURL)

        var affine = makeAffineTransform()
        affine.transformParametersPath = transformURL.path
        var ready = makeSlice(
            status: .affineDone,
            transforms: [makeWorkerPoseTransform(), affine],
            id: "slice-a"
        )
        ready.artifacts = makeAcceptanceArtifacts(
            transformURL: transformURL,
            annotationURL: annotationURL,
            boundaryURL: boundaryURL
        )
        let readyRecord = ready
        let pending = makeSlice(status: .needsReview, transforms: [], id: "slice-b")

        await MainActor.run {
            let store = BrainProjectStore()
            store.registrationProject = makeProject(slices: [readyRecord, pending])
            store.selectedRegistrationSliceID = readyRecord.id

            store.acceptSelectedRegistrationSlice()

            XCTAssertEqual(store.registrationProject?.slices[0].status, .accepted)
            XCTAssertEqual(store.selectedRegistrationSliceID, pending.id)
            XCTAssertEqual(store.workspaceUndoButtonTitle, "Undo Accept")

            store.undoLastWorkspaceAction()

            XCTAssertEqual(store.registrationProject?.slices[0], readyRecord)
            XCTAssertEqual(store.selectedRegistrationSliceID, readyRecord.id)
            XCTAssertNil(store.registrationReviewUndoSnapshot)

            store.selectedRegistrationSliceID = pending.id
            store.rejectSelectedRegistrationSlice()

            XCTAssertEqual(store.registrationProject?.slices[1].status, .failed)
            XCTAssertEqual(store.selectedRegistrationSliceID, readyRecord.id)
            XCTAssertEqual(store.workspaceUndoButtonTitle, "Undo Reject")

            store.undoLastWorkspaceAction()

            XCTAssertEqual(store.registrationProject?.slices[1], pending)
            XCTAssertEqual(store.selectedRegistrationSliceID, pending.id)
        }
    }

    func testAtlasExportBlockersRequireCalibrationStructuralChannelAndAcceptedSlices() {
        let slice = makeSlice(status: .prepared, transforms: [.posePrior(makePose())])
        let project = makeProject(
            pixelSizeMicrons: nil,
            channelMappings: [
                RegistrationChannelMapping(channelIndex: 2, name: "GFP", role: .signal, pseudoColor: "Green")
            ],
            slices: [slice]
        )

        XCTAssertTrue(project.blockersForAtlasExport.contains("Missing physical pixel size calibration."))
        XCTAssertTrue(project.blockersForAtlasExport.contains("No structural registration channel selected."))
        XCTAssertTrue(project.blockersForAtlasExport.contains("1 slice(s) are not accepted after review."))
    }

    func testAtlasExportRejectsAmbiguousStructuralChannels() {
        let project = makeProject(
            channelMappings: [
                RegistrationChannelMapping(channelIndex: 1, name: "DAPI", role: .structural, pseudoColor: "Blue"),
                RegistrationChannelMapping(channelIndex: 2, name: "Autofluorescence", role: .structural, pseudoColor: "Red")
            ],
            slices: [makeSlice(status: .prepared, transforms: [.posePrior(makePose())])]
        )

        XCTAssertTrue(project.blockersForAtlasExport.contains("Select exactly one structural registration channel."))
    }

    func testAcceptedSliceStillRequiresQuantitativeTransform() {
        let slice = makeSlice(status: .accepted, transforms: [.posePrior(makePose())])
        let project = makeProject(slices: [slice])

        XCTAssertTrue(
            project.blockersForAtlasExport.contains(
                "1 accepted slice(s) do not have a usable on-disk atlas-to-slice affine transform."
            )
        )
        XCTAssertTrue(
            project.blockersForAtlasExport.contains(
                "1 accepted slice(s) are missing atlas annotation/boundary artifacts."
            )
        )
    }

    func testAcceptedAffineProjectHasNoExportBlockers() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrainBuilderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let transformURL = folder.appendingPathComponent("affine.tfm")
        let annotationURL = folder.appendingPathComponent("annotation.tif")
        let boundaryURL = folder.appendingPathComponent("boundary.png")
        try Data(
            """
            #Insight Transform File V1.0
            #Transform 0
            Transform: AffineTransform_double_2_2
            Parameters: 1.01 0.02 -0.01 0.99 12 -8
            FixedParameters: 0 0
            """.utf8
        ).write(to: transformURL)
        try writeTestImage(to: annotationURL)
        try writeTestImage(to: boundaryURL)

        var affine = makeAffineTransform()
        affine.transformParametersPath = transformURL.path
        var slice = makeSlice(status: .accepted, transforms: [.posePrior(makePose()), affine])
        slice.artifacts = RegistrationArtifacts(
            preparedImagePath: nil,
            structuralImagePath: nil,
            probeChannelImagePath: nil,
            tissueMaskPath: nil,
            atlasReferencePath: nil,
            registeredImagePath: nil,
            overlayImagePath: nil,
            boundaryImagePath: boundaryURL.path,
            checkerboardImagePath: nil,
            differenceImagePath: nil,
            annotationImagePath: annotationURL.path,
            transformPath: transformURL.path,
            trackMaskPath: nil,
            trackOverlayPath: nil,
            atlasAPIndex: nil
        )
        let project = makeProject(slices: [slice])

        XCTAssertTrue(project.blockersForAtlasExport.isEmpty)
    }

    func testAcceptedSliceRejectsFakeOrMismatchedTransformFile() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrainBuilderTransformTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let transformURL = folder.appendingPathComponent("affine.tfm")
        let annotationURL = folder.appendingPathComponent("annotation.png")
        let boundaryURL = folder.appendingPathComponent("boundary.png")
        try Data("not a SimpleITK transform".utf8).write(to: transformURL)
        try writeTestImage(to: annotationURL)
        try writeTestImage(to: boundaryURL)

        var affine = makeAffineTransform()
        affine.transformParametersPath = transformURL.path
        var slice = makeSlice(status: .accepted, transforms: [.posePrior(makePose()), affine])
        slice.artifacts = RegistrationArtifacts(
            preparedImagePath: nil,
            structuralImagePath: nil,
            probeChannelImagePath: nil,
            tissueMaskPath: nil,
            atlasReferencePath: nil,
            registeredImagePath: nil,
            overlayImagePath: nil,
            boundaryImagePath: boundaryURL.path,
            checkerboardImagePath: nil,
            differenceImagePath: nil,
            annotationImagePath: annotationURL.path,
            transformPath: transformURL.path,
            trackMaskPath: nil,
            trackOverlayPath: nil,
            atlasAPIndex: nil
        )

        XCTAssertTrue(
            makeProject(slices: [slice]).blockersForAtlasExport.contains(
                "1 accepted slice(s) do not have a usable on-disk atlas-to-slice affine transform."
            )
        )

        try Data(
            """
            #Insight Transform File V1.0
            #Transform 0
            Transform: AffineTransform_double_2_2
            Parameters: 1 0 0 1 999 999
            FixedParameters: 0 0
            """.utf8
        ).write(to: transformURL)
        XCTAssertTrue(
            makeProject(slices: [slice]).blockersForAtlasExport.contains(
                "1 accepted slice(s) do not have a usable on-disk atlas-to-slice affine transform."
            )
        )
    }

    func testAcceptedSliceRejectsMismatchedAtlasArtifactDimensions() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrainBuilderArtifactTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let transformURL = folder.appendingPathComponent("affine.tfm")
        let annotationURL = folder.appendingPathComponent("annotation.png")
        let boundaryURL = folder.appendingPathComponent("boundary.png")
        try Data(
            """
            #Insight Transform File V1.0
            #Transform 0
            Transform: AffineTransform_double_2_2
            Parameters: 1.01 0.02 -0.01 0.99 12 -8
            FixedParameters: 0 0
            """.utf8
        ).write(to: transformURL)
        try writeTestImage(to: annotationURL, width: 32, height: 32)
        try writeTestImage(to: boundaryURL, width: 24, height: 32)

        var affine = makeAffineTransform()
        affine.transformParametersPath = transformURL.path
        var slice = makeSlice(status: .accepted, transforms: [.posePrior(makePose()), affine])
        slice.artifacts = RegistrationArtifacts(
            preparedImagePath: nil,
            structuralImagePath: nil,
            probeChannelImagePath: nil,
            tissueMaskPath: nil,
            atlasReferencePath: nil,
            registeredImagePath: nil,
            overlayImagePath: nil,
            boundaryImagePath: boundaryURL.path,
            checkerboardImagePath: nil,
            differenceImagePath: nil,
            annotationImagePath: annotationURL.path,
            transformPath: transformURL.path,
            trackMaskPath: nil,
            trackOverlayPath: nil,
            atlasAPIndex: nil
        )

        XCTAssertTrue(
            makeProject(slices: [slice]).blockersForAtlasExport.contains(
                "1 accepted slice(s) are missing atlas annotation/boundary artifacts."
            )
        )
    }

    func testTransformDirectionInverseIsBidirectional() {
        XCTAssertEqual(TransformDirection.atlasToSlice.inverse, .sliceToAtlas)
        XCTAssertEqual(TransformDirection.sliceToAtlas.inverse, .atlasToSlice)
    }

    func testRegistrationProjectPreservesWorkerProvenanceAcrossSwiftRoundTrip() throws {
        var project = makeProject(
            slices: [makeSlice(status: .prepared, transforms: [.posePrior(makePose())])]
        )
        project.provenance = RegistrationProjectProvenance(
            datasetFingerprint: "dataset-sha256",
            workerVersion: "0.2.0",
            poseEngine: "DeepSlice 1.2.8",
            deepSlicePredictionsPath: "/tmp/deepslice-predictions.csv",
            deepSliceOrientationCandidatesPath: "/tmp/deepslice-orientation-candidates.csv",
            deepSliceGroupOrientations: ["XY01": 0, "XY03": 180],
            deepSliceIndexOrderEnforced: true,
            deepSliceIndexOrderRecheckedAfterAngles: true,
            deepSliceBrainCenterOrderCorrected: true,
            deepSliceUpdatedSliceIDs: ["slice-001"],
            deepSliceFallbackReason: nil,
            sourceImageHashes: ["slice-001": "source-sha256"]
        )
        project.slices[0].artifacts = RegistrationArtifacts(
            preparedImagePath: "/tmp/canonical.png",
            structuralImagePath: "/tmp/canonical.png",
            probeChannelImagePath: "/tmp/canonical-probe.png",
            tissueMaskPath: "/tmp/mask.png",
            atlasReferencePath: nil,
            registeredImagePath: nil,
            overlayImagePath: nil,
            boundaryImagePath: nil,
            checkerboardImagePath: nil,
            differenceImagePath: nil,
            annotationImagePath: nil,
            transformPath: nil,
            trackMaskPath: nil,
            trackOverlayPath: nil,
            atlasAPIndex: nil,
            sourceOverlayImagePath: "/tmp/canonical-overlay.png",
            rawStructuralImagePath: "/tmp/raw.png",
            rawProbeChannelImagePath: "/tmp/raw-probe.png",
            rawSourceOverlayImagePath: "/tmp/raw-overlay.png"
        )
        project.slices[0].canonicalRasterOrientation = RasterOrientation(
            rotationDegrees: 180,
            flipHorizontal: false,
            flipVertical: false
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(
            RegistrationProject.self,
            from: encoder.encode(project)
        )

        XCTAssertEqual(decoded.provenance, project.provenance)
        XCTAssertEqual(decoded.slices[0].artifacts, project.slices[0].artifacts)
        XCTAssertEqual(decoded.slices[0].canonicalRasterOrientation, project.slices[0].canonicalRasterOrientation)
    }

    func testFreshPosePriorIsEligibleForAutomaticOrientationButNotCanonicalPresentation() {
        let project = makeProject(
            slices: [
                makeSlice(
                    status: .unprepared,
                    transforms: [.posePrior(makePose())]
                )
            ]
        )

        XCTAssertTrue(project.canAutomaticallyEstimateInitialSectionOrientation)
        XCTAssertFalse(project.hasCompleteCanonicalSectionOrientation)
    }

    func testDuplicateSliceIDsFailClosedForAutomaticAndVerifiedOrientationContracts() {
        var automatic = makeProject(
            slices: [
                makeSlice(status: .unprepared, transforms: [.posePrior(makePose())], id: "slice-a"),
                makeSlice(status: .unprepared, transforms: [.posePrior(makePose())], id: "slice-b")
            ]
        )
        automatic.slices[1].id = "slice-a"

        XCTAssertFalse(automatic.canAutomaticallyEstimateInitialSectionOrientation)
        XCTAssertFalse(automatic.hasCompleteCanonicalSectionOrientation)

        var verified = makeVerifiedOrientationProject(
            slices: [
                makeVerifiedOrientationSlice(
                    id: "slice-a",
                    groupID: "XY01",
                    rotationDegrees: 0,
                    atlasAPMicrons: 4_200
                ),
                makeVerifiedOrientationSlice(
                    id: "slice-b",
                    groupID: "XY03",
                    rotationDegrees: 180,
                    atlasAPMicrons: 4_400
                )
            ],
            groupOrientations: ["XY01": 0, "XY03": 180]
        )
        verified.slices[1].id = "slice-a"

        XCTAssertFalse(verified.hasCompleteCanonicalSectionOrientation)
        XCTAssertFalse(verified.canAutomaticallyEstimateInitialSectionOrientation)
    }

    func testCompleteDeepSliceBatchWithZeroAndOneEightyDegreeGroupsIsCanonical() {
        let project = makeVerifiedOrientationProject(
            slices: [
                makeVerifiedOrientationSlice(
                    id: "slice-a",
                    groupID: "XY01",
                    rotationDegrees: 0,
                    atlasAPMicrons: 4_200
                ),
                makeVerifiedOrientationSlice(
                    id: "slice-b",
                    groupID: "XY03",
                    rotationDegrees: 180,
                    atlasAPMicrons: 4_400
                )
            ],
            groupOrientations: ["XY01": 0, "XY03": 180]
        )

        XCTAssertTrue(project.hasCompleteCanonicalSectionOrientation)
        XCTAssertFalse(project.canAutomaticallyEstimateInitialSectionOrientation)
    }

    func testIncompleteOrInconsistentDeepSliceBatchIsRejectedForCanonicalPresentation() {
        let complete = makeVerifiedOrientationProject(
            slices: [
                makeVerifiedOrientationSlice(
                    id: "slice-a",
                    groupID: "XY01",
                    rotationDegrees: 0,
                    atlasAPMicrons: 4_200
                ),
                makeVerifiedOrientationSlice(
                    id: "slice-b",
                    groupID: "XY03",
                    rotationDegrees: 180,
                    atlasAPMicrons: 4_400
                )
            ],
            groupOrientations: ["XY01": 0, "XY03": 180]
        )
        XCTAssertTrue(complete.hasCompleteCanonicalSectionOrientation)

        var fallback = complete
        fallback.provenance?.deepSliceFallbackReason = "DeepSlice unavailable"
        XCTAssertFalse(fallback.hasCompleteCanonicalSectionOrientation, "A fallback prior is not verified DeepSlice output")

        var missingGroup = complete
        missingGroup.provenance?.deepSliceGroupOrientations?.removeValue(forKey: "XY03")
        XCTAssertFalse(missingGroup.hasCompleteCanonicalSectionOrientation, "Every current montage group must be covered")

        var missingUpdatedSlice = complete
        missingUpdatedSlice.provenance?.deepSliceUpdatedSliceIDs = ["slice-a"]
        XCTAssertFalse(missingUpdatedSlice.hasCompleteCanonicalSectionOrientation, "Every current slice must be in the worker update set")

        var missingSourceHash = complete
        missingSourceHash.provenance?.sourceImageHashes?.removeValue(forKey: "slice-b")
        XCTAssertFalse(missingSourceHash.hasCompleteCanonicalSectionOrientation, "Every current slice must be bound to its source raster")

        var unsupportedFlip = complete
        unsupportedFlip.slices[1].pose?.flipVertical = true
        XCTAssertFalse(unsupportedFlip.hasCompleteCanonicalSectionOrientation, "Canonical publication does not support flipped worker poses")

        var groupMismatch = complete
        groupMismatch.provenance?.deepSliceGroupOrientations?["XY03"] = 0
        XCTAssertFalse(groupMismatch.hasCompleteCanonicalSectionOrientation, "An unlocked pose must match its batch group decision")

        var orderNotEnforced = complete
        orderNotEnforced.provenance?.deepSliceIndexOrderEnforced = false
        XCTAssertFalse(orderNotEnforced.hasCompleteCanonicalSectionOrientation, "Multi-slice publication requires enforced index order")

        var orderNotRecheckedAfterAngles = complete
        orderNotRecheckedAfterAngles.provenance?.deepSliceIndexOrderRecheckedAfterAngles = false
        XCTAssertFalse(orderNotRecheckedAfterAngles.hasCompleteCanonicalSectionOrientation, "Multi-slice publication requires the post-angle order check")

        var brainCenterOrderNotCorrected = complete
        brainCenterOrderNotCorrected.provenance?.deepSliceBrainCenterOrderCorrected = false
        XCTAssertFalse(brainCenterOrderNotCorrected.hasCompleteCanonicalSectionOrientation, "Multi-slice publication requires corrected brain-center order")

        var scrambledAP = makeVerifiedOrientationProject(
            slices: [
                makeVerifiedOrientationSlice(
                    id: "slice-a",
                    groupID: "XY01",
                    rotationDegrees: 0,
                    atlasAPMicrons: 4_200
                ),
                makeVerifiedOrientationSlice(
                    id: "slice-b",
                    groupID: "XY02",
                    rotationDegrees: 0,
                    atlasAPMicrons: 4_300
                ),
                makeVerifiedOrientationSlice(
                    id: "slice-c",
                    groupID: "XY03",
                    rotationDegrees: 180,
                    atlasAPMicrons: 4_400
                )
            ],
            groupOrientations: ["XY01": 0, "XY02": 0, "XY03": 180]
        )
        XCTAssertTrue(scrambledAP.hasCompleteCanonicalSectionOrientation)
        scrambledAP.slices.swapAt(1, 2)
        XCTAssertFalse(scrambledAP.hasCompleteCanonicalSectionOrientation, "Current slice order must have monotonic AP coordinates")
    }

    func testManuallyLockedSupportedOrientationOverridesDeepSliceGroupDecision() {
        for (workerRotation, reviewerRotation) in [(0, 180), (180, 0)] {
            var slice = makeVerifiedOrientationSlice(
                id: "slice-a",
                groupID: "XY01",
                rotationDegrees: workerRotation
            )
            slice.pose?.rotationDegrees = Double(reviewerRotation)
            slice.pose?.manuallyLocked = true
            slice.pose?.provenance = "Reviewer orientation correction"
            let project = makeVerifiedOrientationProject(
                slices: [slice],
                groupOrientations: ["XY01": workerRotation]
            )

            XCTAssertTrue(
                project.hasCompleteCanonicalSectionOrientation,
                "A locked \(reviewerRotation)-degree correction should remain publishable"
            )
        }
    }

    func testUnlockedReviewerOrientationRetainedAcrossBatchThatSkippedItsSlice() {
        let batchUpdated = makeVerifiedOrientationSlice(
            id: "slice-a",
            groupID: "XY01",
            rotationDegrees: 0,
            atlasAPMicrons: 4_200
        )
        var reviewerRetained = makeVerifiedOrientationSlice(
            id: "slice-b",
            groupID: "XY03",
            rotationDegrees: 180,
            atlasAPMicrons: 4_400
        )
        reviewerRetained.pose?.manuallyLocked = false
        reviewerRetained.pose?.provenance = "Unlocked by reviewer"
        var project = makeVerifiedOrientationProject(
            slices: [batchUpdated, reviewerRetained],
            groupOrientations: ["XY01": 0, "XY03": 0]
        )
        project.provenance?.deepSliceUpdatedSliceIDs = ["slice-a"]

        XCTAssertEqual(
            reviewerRetained.transformChain.transforms.first?.rasterOrientation?.rotationDegrees,
            Int(reviewerRetained.pose?.rotationDegrees ?? -1)
        )
        XCTAssertTrue(project.hasCompleteCanonicalSectionOrientation)
    }

    func testKeyenceCalibrationConvertsNanometersToMicrons() throws {
        let value = try XCTUnwrap(
            KeyenceGCIReader.calibrationMicronsPerPixel("4660518447848644499")
        )

        XCTAssertEqual(value, 3.7744179166666668, accuracy: 1e-9)
        XCTAssertEqual(value * 1_920 / 1_000, 7.2468824, accuracy: 1e-7)
    }

    func testManualOrientationCorrectionInvalidatesAffineAndSynchronizesVolume() async {
        await MainActor.run {
            var slice = makeSlice(
                status: .affineDone,
                transforms: [makeWorkerPoseTransform(), makeAffineTransform()],
                id: "slice-a"
            )
            slice.pose = makeVerifiedWorkerPose(rotationDegrees: 0)
            slice.canonicalRasterOrientation = RasterOrientation(
                rotationDegrees: 0,
                flipHorizontal: false,
                flipVertical: false
            )
            slice.qc.majorRegionIoU = 0.81
            slice.qc.mutualInformationMetric = 0.42
            slice.artifacts = RegistrationArtifacts(
                preparedImagePath: "/tmp/prepared.png",
                structuralImagePath: "/tmp/prepared.png",
                probeChannelImagePath: nil,
                tissueMaskPath: "/tmp/mask.png",
                atlasReferencePath: "/tmp/atlas.png",
                registeredImagePath: "/tmp/registered.png",
                overlayImagePath: "/tmp/overlay.png",
                boundaryImagePath: "/tmp/borders.png",
                checkerboardImagePath: "/tmp/checker.png",
                differenceImagePath: "/tmp/diff.png",
                annotationImagePath: "/tmp/annotation.tif",
                transformPath: "/tmp/affine.tfm",
                trackMaskPath: "/tmp/track-mask.png",
                trackOverlayPath: "/tmp/track.png",
                atlasAPIndex: 123
            )
            let companion = makeVerifiedOrientationSlice(
                id: "slice-b",
                groupID: "XY01",
                rotationDegrees: 0,
                atlasAPMicrons: 4_400
            )
            let store = makeNavigationStore(sliceIDs: ["slice-a", "slice-b"])
            store.registrationProject = makeVerifiedOrientationProject(
                slices: [slice, companion],
                groupOrientations: ["XY01": 0]
            )
            store.selectedRegistrationSliceID = slice.id

            XCTAssertTrue(store.registrationProject?.hasCompleteCanonicalSectionOrientation == true)

            store.rotateSelectedRegistrationSlice180()

            let corrected = store.selectedRegistrationSlice
            XCTAssertEqual(corrected?.pose?.rotationDegrees, 180)
            XCTAssertEqual(corrected?.pose?.manuallyLocked, true)
            XCTAssertEqual(corrected?.status, .poseEstimated)
            XCTAssertEqual(corrected?.transformChain.transforms.map(\.kind), [.pose])
            XCTAssertNil(corrected?.artifacts?.annotationImagePath)
            XCTAssertNil(corrected?.artifacts?.transformPath)
            XCTAssertNil(corrected?.qc.majorRegionIoU)
            XCTAssertTrue(corrected?.qc.warnings.contains(where: { $0.contains("rerun affine") }) == true)
            XCTAssertEqual(store.volume?.slices.first?.rotationDegrees, 180)

            store.undoLastWorkspaceAction()
            XCTAssertEqual(store.selectedRegistrationSlice?.pose?.rotationDegrees, 0)
            XCTAssertEqual(store.volume?.slices.first?.rotationDegrees, 0)
        }
    }

    private func makeProject(
        pixelSizeMicrons: Double? = 0.65,
        channelMappings: [RegistrationChannelMapping] = [
            RegistrationChannelMapping(channelIndex: 1, name: "DAPI", role: .structural, pseudoColor: "Blue")
        ],
        slices: [SliceRegistrationRecord]
    ) -> RegistrationProject {
        RegistrationProject(
            id: "unit-project",
            datasetRootPath: "/tmp/brainbuilder-test",
            atlas: .allenCCF2020,
            orientation: .coronal,
            pixelSizeMicrons: pixelSizeMicrons,
            channelMappings: channelMappings,
            slices: slices,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            sourceMode: .montageSections
        )
    }

    private func makeSlice(
        status: SliceRegistrationStatus,
        transforms: [RegistrationTransform],
        id: String = "slice-001"
    ) -> SliceRegistrationRecord {
        SliceRegistrationRecord(
            id: id,
            title: id,
            groupID: "XY01",
            sourceImagePath: "/tmp/\(id).tif",
            pixelSizeMicrons: 0.65,
            imageSize: PixelSize(width: 1024, height: 768),
            status: status,
            pose: makePose(),
            transformChain: TransformChain(direction: .atlasToSlice, transforms: transforms),
            qc: .empty,
            reviewNotes: ""
        )
    }

    private func makeProbeTrack(candidateID: String) -> ProbeTrackDetection {
        ProbeTrackDetection(
            candidateId: candidateID,
            candidateDigest: String(repeating: "a", count: 64),
            status: "atlasMapped",
            channelName: "probe",
            points: [ProbeTrackPoint(pointId: "point-1", x: 10, y: 20, inlier: true)],
            atlasPoints: [
                AtlasTrackPoint(
                    slicePoint: RegistrationPoint(x: 10, y: 20),
                    apMicrons: 4_200,
                    dorsalVentralMicrons: 1_100,
                    rightLeftMicrons: 2_500,
                    uncertaintyMicrons: 75
                )
            ],
            lineStart: RegistrationPoint(x: 9, y: 18),
            lineEnd: RegistrationPoint(x: 11, y: 22),
            confidence: 0.8,
            rmseMicrons: 42,
            reviewAccepted: true,
            autoQualified: true,
            dorsalEntryDistanceFraction: 0.1,
            provenance: "unit fixture",
            blind: true
        )
    }

    private func makePose() -> SlicePose {
        SlicePose.estimated(apMicrons: 4_200, confidence: 0.7, provenance: "unit")
    }

    private func makeVerifiedWorkerPose(
        rotationDegrees: Int,
        manuallyLocked: Bool = false,
        atlasAPMicrons: Double = 4_200
    ) -> SlicePose {
        SlicePose(
            atlasAPMicrons: atlasAPMicrons,
            atlasSlicingAngles: AtlasSlicingAngles(
                pitchDegrees: 0.25,
                rollDegrees: -0.5,
                yawDegrees: 0.75
            ),
            rotationDegrees: Double(rotationDegrees),
            flipHorizontal: false,
            flipVertical: false,
            sourceConfidence: 0.87,
            manuallyLocked: manuallyLocked,
            provenance: "DeepSlice batch pose",
            atlasAnchoring: [0, 1, 0, 1, 0, 1, 0.25, 0.5, 1],
            predictionImageSize: PixelSize(width: 1024, height: 768)
        )
    }

    private func makeVerifiedOrientationSlice(
        id: String,
        groupID: String,
        rotationDegrees: Int,
        manuallyLocked: Bool = false,
        atlasAPMicrons: Double = 4_200
    ) -> SliceRegistrationRecord {
        var slice = makeSlice(
            status: .poseEstimated,
            transforms: [makeWorkerPoseTransform(rotationDegrees: rotationDegrees)],
            id: id
        )
        slice.groupID = groupID
        slice.pose = makeVerifiedWorkerPose(
            rotationDegrees: rotationDegrees,
            manuallyLocked: manuallyLocked,
            atlasAPMicrons: atlasAPMicrons
        )
        slice.canonicalRasterOrientation = RasterOrientation(
            rotationDegrees: rotationDegrees,
            flipHorizontal: false,
            flipVertical: false
        )
        return slice
    }

    private func makeVerifiedOrientationProject(
        slices: [SliceRegistrationRecord],
        groupOrientations: [String: Int]
    ) -> RegistrationProject {
        var project = makeProject(slices: slices)
        project.provenance = RegistrationProjectProvenance(
            datasetFingerprint: "dataset-sha256",
            workerVersion: "0.2.0",
            poseEngine: "DeepSlice 1.2.8",
            deepSlicePredictionsPath: "/tmp/deepslice-predictions.csv",
            deepSliceOrientationCandidatesPath: "/tmp/deepslice-orientation-candidates.csv",
            deepSliceGroupOrientations: groupOrientations,
            deepSliceIndexOrderEnforced: true,
            deepSliceIndexOrderRecheckedAfterAngles: true,
            deepSliceBrainCenterOrderCorrected: true,
            deepSliceUpdatedSliceIDs: slices.map(\.id),
            deepSliceFallbackReason: nil,
            sourceImageHashes: Dictionary(
                uniqueKeysWithValues: slices.map { ($0.id, "sha256-\($0.id)") }
            )
        )
        return project
    }

    private func makeWorkerPoseTransform(rotationDegrees: Int = 0) -> RegistrationTransform {
        RegistrationTransform(
            id: "worker-pose",
            kind: .pose,
            stage: .pose,
            direction: .atlasToSlice,
            engine: "DeepSlice 1.2.8",
            affine: .identity,
            transformParametersPath: nil,
            landmarks: [],
            metric: 0.78,
            createdAt: Date(timeIntervalSince1970: 2),
            provenance: "worker estimate",
            rasterOrientation: RasterOrientation(
                rotationDegrees: rotationDegrees,
                flipHorizontal: false,
                flipVertical: false
            )
        )
    }

    private func makeAcceptanceArtifacts(
        transformURL: URL,
        annotationURL: URL,
        boundaryURL: URL
    ) -> RegistrationArtifacts {
        RegistrationArtifacts(
            preparedImagePath: nil,
            structuralImagePath: nil,
            probeChannelImagePath: nil,
            tissueMaskPath: nil,
            atlasReferencePath: nil,
            registeredImagePath: nil,
            overlayImagePath: nil,
            boundaryImagePath: boundaryURL.path,
            checkerboardImagePath: nil,
            differenceImagePath: nil,
            annotationImagePath: annotationURL.path,
            transformPath: transformURL.path,
            trackMaskPath: nil,
            trackOverlayPath: nil,
            atlasAPIndex: nil
        )
    }

    private func writeInsightAffine(to url: URL) throws {
        try Data(
            """
            #Insight Transform File V1.0
            #Transform 0
            Transform: AffineTransform_double_2_2
            Parameters: 1.01 0.02 -0.01 0.99 12 -8
            FixedParameters: 0 0
            """.utf8
        ).write(to: url)
    }

    private func writeTestImage(to url: URL, width: Int = 32, height: Int = 32) throws {
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }

    private func makeAffineTransform() -> RegistrationTransform {
        RegistrationTransform(
            id: "affine",
            kind: .affine,
            stage: .affine,
            direction: .atlasToSlice,
            engine: "unit-test",
            affine: AffineTransform2D(m00: 1.01, m01: 0.02, m10: -0.01, m11: 0.99, tx: 12, ty: -8),
            transformParametersPath: "TransformParameters.0.txt",
            landmarks: [],
            metric: 0.82,
            createdAt: Date(timeIntervalSince1970: 2),
            provenance: "synthetic affine",
            coordinateUnit: "micron"
        )
    }

    private func makeSignal(
        area: Int,
        bounds: CGRect,
        foregroundConfidence: Double
    ) -> SliceSignal {
        SliceSignal(
            redMean: 0,
            greenMean: 0,
            blueMean: 0,
            alphaCoverage: 0.5,
            tissueBounds: bounds,
            imageSize: PixelSize(width: 140, height: 100),
            componentAreaPixels: area,
            componentBounds: bounds,
            foregroundConfidence: foregroundConfidence,
            backgroundSuppression: 0.4
        )
    }

    @MainActor
    private func makeNavigationStore(sliceIDs: [String]) -> BrainProjectStore {
        let store = BrainProjectStore()
        let signal = makeSignal(
            area: 7_200,
            bounds: CGRect(x: 20, y: 12, width: 100, height: 80),
            foregroundConfidence: 0.92
        )
        let slices = sliceIDs.enumerated().map { index, id in
            VolumeSlice(
                id: id,
                title: "Slice \(index + 1)",
                sourceURL: URL(fileURLWithPath: "/tmp/\(id).tif"),
                groupID: "XY01",
                texture: makeTestTexture(),
                width: 8,
                height: 8,
                z: Double(index),
                offsetX: 0,
                offsetY: 0,
                opacity: 1,
                signal: signal,
                registration: .unregistered,
                cortex: .unregistered
            )
        }
        store.volume = BrainVolume(
            sourceMode: .montageSections,
            slices: slices,
            bounds: SIMD3<Double>(8, 8, Double(max(1, slices.count))),
            atlasRegistration: .empty,
            cortexRegistration: .empty,
            buildSummary: VolumeBuildSummary(
                sourceImages: slices.count,
                producedSlices: slices.count,
                rejectedComponents: 0,
                maxTexturePixels: 64,
                meanForegroundConfidence: 0.92,
                meanBackgroundRemoved: 0.4
            ),
            reliabilityReport: .empty
        )
        return store
    }

    private func makeTestTexture() -> NSImage {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 8,
            pixelsHigh: 8,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.addRepresentation(bitmap)
        return image
    }
}
