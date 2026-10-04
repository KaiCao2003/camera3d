import Foundation
import SceneKit
import XCTest
@testable import BrainBuilder

final class AllenAtlasServiceTests: XCTestCase {
    func testModelIOValidationAcceptsUsableOBJGeometry() throws {
        let url = try temporaryOBJ(
            contents: """
            o root
            v 0 0 0
            v 1 0 0
            v 0 1 1
            f 1 2 3
            """
        )

        let result = AllenAtlasService.loadValidatedReferenceGeometry(at: url)

        switch result {
        case let .success(reference):
            XCTAssertGreaterThanOrEqual(reference.metrics.vertexCount, 3)
            XCTAssertGreaterThan(reference.metrics.primitiveCount, 0)
            XCTAssertFalse(reference.geometry.sources(for: .normal).isEmpty)
        case let .failure(error):
            XCTFail("Expected usable OBJ geometry, got \(error.localizedDescription)")
        }
    }

    func testModelIOValidationRejectsFileWithoutGeometry() throws {
        let url = try temporaryOBJ(contents: "this file contains no mesh")

        let result = AllenAtlasService.loadValidatedReferenceGeometry(at: url)

        guard case let .failure(error) = result else {
            return XCTFail("A file without geometry must not be reported as loaded")
        }
        guard case .invalidGeometry = error else {
            return XCTFail("Expected invalid geometry, got \(error)")
        }
    }

    func testInstalledBrainGlobeRootMeshPassesFullGeometryValidation() throws {
        let url = AllenAtlasCatalog.rootStructureMeshURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("BrainGlobe root mesh is not installed in this test environment")
        }

        let result = AllenAtlasService.loadValidatedReferenceGeometry(at: url)

        switch result {
        case let .success(reference):
            XCTAssertEqual(reference.metrics.vertexCount, 49_324)
            XCTAssertEqual(reference.metrics.primitiveCount, 98_638)
        case let .failure(error):
            XCTFail("Installed BrainGlobe mesh failed validation: \(error.localizedDescription)")
        }
    }

    @MainActor
    func testServicePublishesLoadedOnlyAfterGeometryValidationCompletes() async throws {
        let url = try temporaryOBJ(
            contents: """
            o root
            v 0 0 0
            v 1 0 0
            v 0 1 1
            f 1 2 3
            """
        )
        let service = AllenAtlasService(referenceMeshURL: url)
        let completed = expectation(description: "validated geometry loaded")
        var result: Result<AllenReferenceGeometry, AllenReferenceMeshLoadError>?

        XCTAssertEqual(service.referenceMeshState, .loading)
        service.loadRootReferenceGeometry {
            result = $0
            completed.fulfill()
        }
        XCTAssertEqual(service.referenceMeshState, .loading)

        await fulfillment(of: [completed], timeout: 3)

        guard case let .success(reference) = result else {
            return XCTFail("Expected validated reference geometry")
        }
        XCTAssertEqual(service.referenceMeshState, .loaded(reference.metrics))
    }

    @MainActor
    func testServicePublishesFailedForPresentButInvalidGeometry() async throws {
        let url = try temporaryOBJ(contents: "this file contains no mesh")
        let service = AllenAtlasService(referenceMeshURL: url)
        let completed = expectation(description: "invalid geometry rejected")

        service.loadRootReferenceGeometry { _ in completed.fulfill() }
        await fulfillment(of: [completed], timeout: 3)

        guard case let .failed(message) = service.referenceMeshState else {
            return XCTFail("A present but invalid file must be failed, not loaded or unavailable")
        }
        XCTAssertTrue(message.contains("Expected one mesh"))
    }

    @MainActor
    func testNewerLoadGenerationDiscardsStaleGeometry() async throws {
        let url = try temporaryOBJ(
            contents: """
            o root
            v 0 0 0
            v 1 0 0
            v 0 1 1
            f 1 2 3
            """
        )
        let firstStarted = expectation(description: "first generation started")
        let newestFinished = expectation(description: "newest generation finished")
        let releaseFirst = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var callCount = 0
        let service = AllenAtlasService(
            referenceMeshURL: url,
            referenceGeometryLoader: { _ in
                lock.lock()
                callCount += 1
                let call = callCount
                lock.unlock()
                if call == 1 {
                    firstStarted.fulfill()
                    releaseFirst.wait()
                }
                let metrics = AllenReferenceMeshMetrics(
                    vertexCount: call == 1 ? 111 : 222,
                    primitiveCount: call
                )
                return .success(
                    AllenReferenceGeometry(
                        geometry: SCNGeometry(),
                        metrics: metrics
                    )
                )
            }
        )
        var firstResult: Result<AllenReferenceGeometry, AllenReferenceMeshLoadError>?
        var newestResult: Result<AllenReferenceGeometry, AllenReferenceMeshLoadError>?

        service.loadRootReferenceGeometry { firstResult = $0 }
        await fulfillment(of: [firstStarted], timeout: 2)
        service.loadRootReferenceGeometry(forceReload: true) {
            newestResult = $0
            newestFinished.fulfill()
        }
        releaseFirst.signal()

        await fulfillment(of: [newestFinished], timeout: 3)

        guard case .failure(.superseded) = firstResult else {
            return XCTFail("The older callback must be marked superseded")
        }
        guard case let .success(reference) = newestResult else {
            return XCTFail("The newest generation must finish successfully")
        }
        XCTAssertEqual(reference.metrics.vertexCount, 222)
        XCTAssertEqual(service.referenceMeshState, .loaded(reference.metrics))
    }

    @MainActor
    func testMissingReferenceIsUnavailableWithoutInvokingLoader() throws {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("obj")
        var didInvokeLoader = false
        let service = AllenAtlasService(
            referenceMeshURL: missingURL,
            referenceGeometryLoader: { _ in
                didInvokeLoader = true
                return .failure(.invalidGeometry("unexpected"))
            }
        )
        var result: Result<AllenReferenceGeometry, AllenReferenceMeshLoadError>?

        service.loadRootReferenceGeometry { result = $0 }

        XCTAssertEqual(service.referenceMeshState, .unavailable)
        XCTAssertFalse(didInvokeLoader)
        guard case .failure(.unavailable) = result else {
            return XCTFail("Missing mesh must report unavailable")
        }
    }

    private func temporaryOBJ(contents: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrainBuilder-AllenAtlasServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: folder)
        }
        let url = folder.appendingPathComponent("997.obj")
        try Data(contents.utf8).write(to: url, options: .atomic)
        return url
    }
}
