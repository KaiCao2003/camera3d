import XCTest
@testable import BrainBuilder

final class RegistrationCorrectionTests: XCTestCase {
    func testLandmarksNeedIndependentTwoDimensionalSupportInBothImages() {
        var correction = RegistrationCorrection(pose: .estimated(apMicrons: 8000, confidence: 0, provenance: "test"))
        correction.landmarks = pairs([(0, 0), (10, 10), (20, 20)])
        XCTAssertFalse(correction.hasUsableLandmarks)
        correction.landmarks = pairs([(0, 0), (10, 0), (0, 10)])
        XCTAssertTrue(correction.hasUsableLandmarks)
        correction.landmarks[2].slicePoint = RegistrationPoint(x: 20, y: 0)
        XCTAssertFalse(correction.hasUsableLandmarks)
        correction.landmarks[2].slicePoint = RegistrationPoint(x: .nan, y: 10)
        XCTAssertFalse(correction.hasUsableLandmarks)
    }

    func testCorrectionUsesThePersistedQuickNIIPlaneAngles() throws {
        var pose = SlicePose.estimated(apMicrons: 7900, confidence: 0, provenance: "test")
        pose.atlasSlicingAngles = AtlasSlicingAngles(pitchDegrees: 4, rollDegrees: -7, yawDegrees: 0)
        var correction = RegistrationCorrection(pose: pose)
        XCTAssertEqual(correction.yawDegrees, -7)
        XCTAssertTrue(correction.matchesPlane(pose))
        correction.atlasAPMicrons += 25
        XCTAssertFalse(correction.matchesPlane(pose))
        XCTAssertEqual(try JSONDecoder().decode(RegistrationCorrection.self, from: JSONEncoder().encode(correction)), correction)
    }

    func testPoseDiagnosticsSurviveSwiftPersistence() throws {
        let json = Data(#"{"warnings":[],"majorRegionIoU":0.9,"rawPoseAPMicrons":8000,"orderedPoseAPMicrons":8450,"poseAdjustmentMicrons":450}"#.utf8)
        let decoded = try JSONDecoder().decode(RegistrationQC.self, from: json)
        let restored = try JSONDecoder().decode(RegistrationQC.self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(restored.poseAdjustmentMicrons, 450)
        XCTAssertEqual(restored.rawPoseAPMicrons, 8000)
        XCTAssertEqual(restored.orderedPoseAPMicrons, 8450)
    }

    func testManualPlaneRemainsPresentableAfterSaveAndReload() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let original = root.appendingPathComponent("evidence/2026-10-02/project-before-repair.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var project = try decoder.decode(RegistrationProject.self, from: Data(contentsOf: original))
        project.slices[0].pose?.manuallyLocked = true
        project.slices[0].pose?.atlasAPMicrons = 8000
        let index = try XCTUnwrap(project.slices[0].transformChain.transforms.firstIndex { $0.kind == .pose })
        project.slices[0].transformChain.transforms[index].engine = "Manual QuickNII plane correction 0.2.0"
        XCTAssertTrue(project.hasCompleteCanonicalSectionOrientation)
        project.slices[0].pose?.manuallyLocked = false
        XCTAssertFalse(project.hasCompleteCanonicalSectionOrientation)
    }

    private func pairs(_ positions: [(Double, Double)]) -> [ManualLandmarkPair] {
        positions.enumerated().map { index, position in
            let point = RegistrationPoint(x: position.0, y: position.1)
            return ManualLandmarkPair(id: "\(index)", atlasPoint: point, slicePoint: point, label: "\(index)")
        }
    }
}
