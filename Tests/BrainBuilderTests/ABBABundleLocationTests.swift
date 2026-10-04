import Foundation
import XCTest
@testable import BrainBuilder

final class ABBABundleLocationTests: XCTestCase {
    func testExistingResultBundleIsLocatedWithoutChangingSourceFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundle = root.appendingPathComponent("handoff", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = root.appendingPathComponent("result.json")
        let data = try JSONSerialization.data(withJSONObject: ["bundlePath": bundle.path])
        try data.write(to: result)

        XCTAssertEqual(BrainProjectStore.existingABBABundleURL(for: result), bundle)
        XCTAssertEqual(try Data(contentsOf: result), data)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: bundle.path).isEmpty)
    }

    func testLegacyOrMovedBundleRequiresFolderSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = root.appendingPathComponent("result.json")
        let cases: [[String: String]] = [
            [:],
            ["bundlePath": root.appendingPathComponent("moved-handoff").path],
            ["bundlePath": result.path],
            ["bundlePath": "relative-handoff"]
        ]
        for document in cases {
            try JSONSerialization.data(withJSONObject: document).write(to: result)
            XCTAssertNil(BrainProjectStore.existingABBABundleURL(for: result))
        }
    }
}
