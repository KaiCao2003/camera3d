import XCTest
@testable import BrainBuilder

final class LegacyRegistrationProjectTests: XCTestCase {
    func testOriginalSavedProjectRestoresAllRegisteredSections() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let backup = root.appendingPathComponent("evidence/2026-10-02/project-before-repair.json")
        let data = try Data(contentsOf: backup)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(RegistrationProject.self, from: data)

        XCTAssertFalse(project.blindReviewLocked)
        XCTAssertEqual(project.slices.count, 24)
        XCTAssertEqual(project.slices.filter { $0.status == .affineDone }.count, 18)
        XCTAssertEqual(project.slices.filter { $0.status == .needsReview }.count, 6)
        XCTAssertEqual(project.slices.filter { $0.transformChain.hasQuantitativeTransform }.count, 24)
        XCTAssertTrue(project.hasCompleteCanonicalSectionOrientation)

        let restored = try RegistrationWorkerService().readProject(at: backup)
        XCTAssertEqual(restored.slices.map(\.id), project.slices.map(\.id))
        XCTAssertEqual(restored.slices.map(\.status), project.slices.map(\.status))
        XCTAssertEqual(try Data(contentsOf: backup), data)
    }

    @MainActor
    func testOriginalSavedProjectIsRestoredByCandidateLoader() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let dataset = BrainDataset(rootURL: folder.appendingPathComponent("data"), groups: [])
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let original = try Data(contentsOf: root.appendingPathComponent("evidence/2026-10-02/project-before-repair.json"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        object["datasetRootPath"] = dataset.rootURL.path
        let data = try JSONSerialization.data(withJSONObject: object)
        let url = savedProjectURL(in: folder)
        try data.write(to: url)
        let reference = try RegistrationWorkerService().readProject(at: url)

        let restored = try XCTUnwrap(BrainProjectStore().loadPersistedRegistrationProjectCandidate(
            for: dataset,
            mode: .montageSections,
            expectedFingerprint: reference.provenance?.datasetFingerprint
        ))

        XCTAssertEqual(restored.slices, reference.slices)
        XCTAssertEqual(restored.slices.filter { $0.status == .affineDone }.count, 18)
        XCTAssertEqual(restored.slices.filter { $0.status == .needsReview }.count, 6)
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    @MainActor
    func testInvalidSavedProjectPreventsAutomaticRecreationAndPreservesFile() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = savedProjectURL(in: folder)
        let invalid = Data("{\"slices\": [interrupted JSON".utf8)
        try invalid.write(to: url)
        let store = BrainProjectStore()
        store.dataset = BrainDataset(rootURL: folder.appendingPathComponent("data"), groups: [])

        await store.rebuildVolume()
        store.retrySectionOrientation()
        await Task.yield()

        XCTAssertNil(store.registrationProject)
        XCTAssertNil(store.volume)
        XCTAssertFalse(store.isRunningRegistrationWorker)
        XCTAssertTrue(store.status.contains("Saved registration could not be loaded"), store.status)
        XCTAssertTrue(store.status.contains(url.path), store.status)
        XCTAssertTrue(store.status.contains("saved file has been preserved"), store.status)
        XCTAssertFalse(store.sectionOrientationState.permitsSectionRasterPresentation)
        XCTAssertEqual(try Data(contentsOf: url), invalid)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: url.deletingPathExtension().appendingPathExtension("review.json").path
        ))
    }

    @MainActor
    func testUnknownSchemaIsRejectedAndPreserved() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let dataset = BrainDataset(rootURL: folder.appendingPathComponent("data"), groups: [])
        var project = RegistrationWorkerService().makeProject(dataset: dataset, volume: nil)
        project.schemaVersion = 99
        let url = savedProjectURL(in: folder)
        try RegistrationWorkerService().write(project, to: url)
        let original = try Data(contentsOf: url)

        XCTAssertThrowsError(try RegistrationWorkerService().readProject(at: url)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Unsupported registration project schema 99"))
        }
        let store = BrainProjectStore()
        store.dataset = dataset
        await store.rebuildVolume()

        XCTAssertNil(store.registrationProject)
        XCTAssertFalse(store.isRunningRegistrationWorker)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    @MainActor
    func testRebuildingUnchangedDatasetPreservesBlindReviewState() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let dataset = BrainDataset(rootURL: folder.appendingPathComponent("data"), groups: [])
        let volume = try BrainVolumeBuilder().build(dataset: dataset, mode: .montageSections)
        var project = RegistrationWorkerService().makeProject(dataset: dataset, volume: volume)
        project.blindReviewLocked = true
        project.blindTrackReview = BlindTrackReviewState(groups: [], unassignedSourcePointIDs: ["point-1"])
        project.blindTrackReviewPreview = BlindTrackReviewPreview(
            schemaVersion: 1,
            reviewedTrackSetSha256: String(repeating: "a", count: 64),
            reviewStateSha256: String(repeating: "b", count: 64),
            tracks: [],
            unassignedSourcePointIDs: ["point-1"],
            usableForNavigation: false
        )
        project.brain3dContext = Brain3DContext(
            handoff: Brain3DHistologyHandoff(raw: [:]),
            priorReceipt: Brain3DPriorReceipt(
                handoffId: "handoff-1",
                handoffSha256: String(repeating: "c", count: 64),
                sourceProjectId: "project-1",
                sourceProjectRevision: 1,
                sourceSubjectId: "mouse-1"
            ),
            subjectBinding: Brain3DSubjectBinding(
                state: .exactMatch,
                planSubjectId: "mouse-1",
                datasetSubjectId: "mouse-1",
                datasetFingerprint: try XCTUnwrap(project.provenance?.datasetFingerprint)
            ),
            blindReviewLocked: true
        )
        try RegistrationWorkerService().write(project, to: savedProjectURL(in: folder))
        let store = BrainProjectStore()
        store.dataset = dataset

        await store.rebuildVolume()

        let restored = try XCTUnwrap(store.registrationProject)
        XCTAssertEqual(restored.brain3dContext, project.brain3dContext)
        XCTAssertEqual(restored.blindReviewLocked, project.blindReviewLocked)
        XCTAssertEqual(restored.blindTrackReview, project.blindTrackReview)
        XCTAssertEqual(restored.blindTrackReviewPreview, project.blindTrackReviewPreview)
    }

    private func makeTemporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("registration-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("data"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: savedProjectURL(in: folder).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return folder
    }

    private func savedProjectURL(in folder: URL) -> URL {
        folder.appendingPathComponent("exports/registration-worker/saved-projects/data-montageSections.json")
    }
}
