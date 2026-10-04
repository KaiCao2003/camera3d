import Foundation
import XCTest
@testable import BrainBuilder

final class MouseLineIntegrationTests: XCTestCase {
    private let goldenDigest = "f1ca6416cec2d5ac3f1d312527e68a07cfbef141ac1270b87ce56071a8dd8fbe"

    func testMouseLineSchemaOneGoldenReceiptValidatesAcrossPythonAndSwift() throws {
        let resolution = try MouseLineSubjectService.decodeAndValidate(
            goldenResponse(),
            expectedIdentifier: "ML-2026-0001"
        )

        XCTAssertEqual(resolution.schemaVersion, 1)
        XCTAssertEqual(resolution.service, "mouse_line")
        XCTAssertEqual(resolution.subject.publicId, "ML-2026-0001")
        XCTAssertEqual(resolution.subject.mouseUser, "研究员")
        XCTAssertEqual(resolution.matchedBy, .publicId)
        XCTAssertEqual(resolution.subjectRecordSha256, goldenDigest)
        XCTAssertTrue(resolution.isExactPublicIDMatch(for: "ML-2026-0001"))
        XCTAssertFalse(resolution.usableForNavigation)

        let receipt = MouseLineSubjectService().makeReceipt(
            from: resolution,
            verifiedAt: Date(timeIntervalSince1970: 123)
        )
        XCTAssertEqual(receipt.publicId, "ML-2026-0001")
        XCTAssertEqual(receipt.sshHost, "hhw9l84")
        XCTAssertEqual(receipt.sshRemotePort, 3_004)
        XCTAssertFalse(receipt.usableForNavigation)
    }

    func testMouseLineReceiptRejectsTamperingAndUnknownSchemaMembers() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: goldenResponse()) as? [String: Any]
        )
        var subject = try XCTUnwrap(object["subject"] as? [String: Any])
        subject["status"] = "transferred"
        object["subject"] = subject
        let tampered = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(
            try MouseLineSubjectService.decodeAndValidate(
                tampered,
                expectedIdentifier: "ML-2026-0001"
            )
        )

        object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: goldenResponse()) as? [String: Any]
        )
        object["unexpected"] = true
        let unknown = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(
            try MouseLineSubjectService.decodeAndValidate(
                unknown,
                expectedIdentifier: "ML-2026-0001"
            )
        )
    }

    func testLegacyIdentifierResultCannotBecomeAnExactSubjectReceipt() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: goldenResponse()) as? [String: Any]
        )
        object["queryIdentifier"] = "legacy-42"
        object["matchedBy"] = "legacyId"
        let data = try JSONSerialization.data(withJSONObject: object)
        let resolution = try MouseLineSubjectService.decodeAndValidate(
            data,
            expectedIdentifier: "legacy-42"
        )

        XCTAssertEqual(resolution.subject.publicId, "ML-2026-0001")
        XCTAssertEqual(resolution.matchedBy, .legacyId)
        XCTAssertFalse(resolution.isExactPublicIDMatch(for: "legacy-42"))
    }

    func testChangingProjectSubjectClearsPersistedColonyReceipt() async {
        await MainActor.run {
            let store = BrainProjectStore()
            var project = makeProject(subjectID: "ML-2026-0001")
            project.colonySubjectReceipt = makeReceipt(publicID: "ML-2026-0001")
            store.registrationProject = project

            store.setRegistrationSubjectID("ML-2026-0001")
            XCTAssertNotNil(store.registrationProject?.colonySubjectReceipt)

            store.setRegistrationSubjectID("ML-2026-0002")
            XCTAssertNil(store.registrationProject?.colonySubjectReceipt)
        }
    }

    func testStaleMouseLineResolutionCannotOverwriteChangedProject() async throws {
        let resolution = try MouseLineSubjectService.decodeAndValidate(
            goldenResponse(),
            expectedIdentifier: "ML-2026-0001"
        )
        await MainActor.run {
            let store = BrainProjectStore()
            let requested = makeProject(subjectID: "ML-2026-0001")
            var changed = requested
            changed.subjectID = "ML-2026-0002"
            store.registrationProject = changed

            XCTAssertFalse(
                store.applyMouseLineResolution(
                    resolution,
                    requestedProject: requested,
                    requestedSubjectID: "ML-2026-0001"
                )
            )
            XCTAssertEqual(store.registrationProject?.subjectID, "ML-2026-0002")
            XCTAssertNil(store.registrationProject?.colonySubjectReceipt)
            XCTAssertNil(store.mouseLineResolution)
        }
    }

    func testCompactReceiptRoundTripsWithoutAnyTokenField() throws {
        var project = makeProject(subjectID: "ML-2026-0001")
        project.colonySubjectReceipt = makeReceipt(publicID: "ML-2026-0001")
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mouse-line-receipt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("project.json")

        let service = RegistrationWorkerService()
        try service.write(project, to: url)
        let bytes = try Data(contentsOf: url)
        let encoded = String(decoding: bytes, as: UTF8.self)
        let decoded = try service.readProject(at: url)

        XCTAssertEqual(decoded.colonySubjectReceipt, project.colonySubjectReceipt)
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("token"))
        XCTAssertTrue(encoded.contains("colonySubjectReceipt"))
    }

    func testManagedTunnelStartsOnlyWhenTheLoopbackPortRefusesConnection() {
        XCTAssertTrue(
            MouseLineSubjectService.shouldStartManagedTunnel(
                after: URLError(.cannotConnectToHost)
            )
        )
        XCTAssertFalse(
            MouseLineSubjectService.shouldStartManagedTunnel(
                after: URLError(.timedOut)
            )
        )
        XCTAssertFalse(
            MouseLineSubjectService.shouldStartManagedTunnel(
                after: MouseLineIntegrationError.server(
                    status: 401,
                    code: "invalid_token",
                    detail: "A bearer token is required."
                )
            )
        )
    }

    private func goldenResponse() -> Data {
        Data(
            #"""
            {
              "schemaVersion": 1,
              "service": "mouse_line",
              "subject": {
                "publicId": "ML-2026-0001",
                "legacyId": "legacy-42",
                "status": "active",
                "sex": "F",
                "dateOfBirth": "2026-01-02",
                "genotype": "Ai32/WT",
                "mouseUser": "研究员",
                "updatedAt": "2026-08-01T12:00:00+00:00",
                "cage": {
                  "cageCardId": "API-CAGE",
                  "status": "active",
                  "room": "ROOM-REGULAR",
                  "protocol": "PROTO-1"
                },
                "surgeries": [
                  {"date": "2026-07-01", "time": "09:30", "operator": "Planner", "type": "implant"}
                ]
              },
              "queryIdentifier": "ML-2026-0001",
              "matchedBy": "publicId",
              "subjectRecordSha256": "f1ca6416cec2d5ac3f1d312527e68a07cfbef141ac1270b87ce56071a8dd8fbe",
              "usableForNavigation": false
            }
            """#.utf8
        )
    }

    private func makeProject(subjectID: String) -> RegistrationProject {
        RegistrationProject(
            id: "mouse-line-unit-project",
            subjectID: subjectID,
            datasetRootPath: "/tmp/brainbuilder-mouse-line-test",
            atlas: .allenCCF2020,
            orientation: .coronal,
            pixelSizeMicrons: 0.65,
            channelMappings: [],
            slices: [],
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            sourceMode: .montageSections
        )
    }

    private func makeReceipt(publicID: String) -> ColonySubjectReceipt {
        ColonySubjectReceipt(
            schemaVersion: 1,
            service: "mouse_line",
            publicId: publicID,
            queryIdentifier: publicID,
            matchedBy: .publicId,
            subjectRecordSha256: goldenDigest,
            verifiedAt: Date(timeIntervalSince1970: 123),
            sshHost: "hhw9l84",
            sshRemotePort: 3_004,
            usableForNavigation: false
        )
    }
}
