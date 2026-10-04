import CryptoKit
import Foundation
import XCTest
@testable import BrainBuilder

final class Brain3DPlanImportServiceTests: XCTestCase {
    func testHistologyMemberLimitMatchesBrain3DAndAcceptsMoreThanLegacySixteenMiB() throws {
        XCTAssertEqual(Brain3DPlanImportService.maximumHistologyDocumentBytes, 32 * 1024 * 1024)

        let projectID = "11111111-1111-4111-8111-111111111111"
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("brain3d-large-histology-\(UUID().uuidString).mouseplan", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }

        let objects: [String: Any] = [
            "project.json": [
                "schema_version": 10,
                "project_uuid": projectID,
                "project_revision": 1,
                "subject_id": "ML-2026-0001",
            ],
            "atlas.json": [
                "atlas_key": "allen_mouse_25um",
                "atlas_package_version": "1.2",
                "standardized_orientation": "asr",
                "resolution_um": [25, 25, 25],
                "shape_voxels": [528, 320, 456],
                "metadata_sha256": String(repeating: "a", count: 64),
            ],
            "regions.json": ["regions": []],
            "vasculature.json": ["layers": []],
        ]
        var checksums: [String: String] = [:]
        for (name, object) in objects {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try data.write(to: package.appendingPathComponent(name))
            checksums[name] = sha256(data)
        }

        let targetSize = 16 * 1024 * 1024 + 1
        var histologyData = Data(
            #"{"brainbuilder_evidence":[],"locked_handoffs":[],"schema_version":1}"#.utf8
        )
        XCTAssertLessThan(histologyData.count, targetSize)
        histologyData.append(Data(repeating: 0x20, count: targetSize - histologyData.count))
        try histologyData.write(to: package.appendingPathComponent("histology.json"))
        checksums["histology.json"] = sha256(histologyData)

        let checksumData = try JSONSerialization.data(withJSONObject: checksums, options: [.sortedKeys])
        try checksumData.write(to: package.appendingPathComponent("checksums.json"))

        let imported = try Brain3DPlanImportService().loadPackage(at: package)

        XCTAssertEqual(imported.projectID, projectID)
        XCTAssertTrue(imported.handoffs.isEmpty)
    }

    func testStrictCurrentHandoffWithNestedROIAndShankDigestsImports() throws {
        let handoff = try makeValidHandoff()
        let package = try makePackage(handoff: handoff)
        defer { try? FileManager.default.removeItem(at: package) }

        let imported = try Brain3DPlanImportService().loadPackage(at: package)

        XCTAssertEqual(imported.handoffs.count, 1)
        XCTAssertEqual(imported.handoffs[0].handoffSHA256, handoff["handoff_sha256"] as? String)
    }

    func testDeepHandoffObjectsRejectUnknownFieldsEvenWithRefreshedDigests() throws {
        try assertUnknownFieldRejected { handoff in
            var project = handoff["project"] as! [String: Any]
            project["unknown"] = true
            handoff["project"] = project
        }
        try assertUnknownFieldRejected { handoff in
            var subject = handoff["subject"] as! [String: Any]
            subject["unknown"] = true
            handoff["subject"] = subject
        }
        try assertUnknownFieldRejected { handoff in
            var rois = handoff["roi_sets"] as! [[String: Any]]
            rois[0]["unknown"] = true
            handoff["roi_sets"] = rois
        }
        try assertUnknownFieldRejected { handoff in
            var rois = handoff["roi_sets"] as! [[String: Any]]
            var structures = rois[0]["allen_structures"] as! [[String: Any]]
            structures[0]["unknown"] = true
            rois[0]["allen_structures"] = structures
            handoff["roi_sets"] = rois
        }
        try assertUnknownFieldRejected { handoff in
            var rois = handoff["roi_sets"] as! [[String: Any]]
            var boxes = rois[0]["asr_boxes"] as! [[String: Any]]
            boxes[0]["unknown"] = true
            rois[0]["asr_boxes"] = boxes
            handoff["roi_sets"] = rois
        }
        try assertUnknownFieldRejected { handoff in
            var snapshots = handoff["insertion_snapshots"] as! [[String: Any]]
            snapshots[0]["unknown"] = true
            handoff["insertion_snapshots"] = snapshots
        }
        try assertUnknownFieldRejected { handoff in
            var snapshots = handoff["insertion_snapshots"] as! [[String: Any]]
            var shanks = snapshots[0]["planned_shanks"] as! [[String: Any]]
            shanks[0]["unknown"] = true
            snapshots[0]["planned_shanks"] = shanks
            handoff["insertion_snapshots"] = snapshots
        }
    }

    func testPackageRejectsUndeclaredChecksummedMember() throws {
        let package = try makePackage(
            handoff: nil,
            extraFiles: ["unexpected.bin": Data("ignored".utf8)]
        )
        defer { try? FileManager.default.removeItem(at: package) }

        XCTAssertThrowsError(try Brain3DPlanImportService().loadPackage(at: package))
    }

    func testDeclaredSubjectAssetIsAcceptedAndBoundToProjectReceipt() throws {
        let asset = Data("vascular-image-fixture".utf8)
        let declaration = subjectAsset(path: "images/subject.png", data: asset)
        let package = try makePackage(
            handoff: nil,
            subjectAssets: [declaration],
            assetFiles: ["images/subject.png": asset]
        )
        defer { try? FileManager.default.removeItem(at: package) }

        XCTAssertNoThrow(try Brain3DPlanImportService().loadPackage(at: package))
    }

    func testOversizedDeclaredAssetIsRejectedBeforeHashing() throws {
        let declaredSize = Brain3DPlanImportService.maximumSubjectAssetBytes
        let declaration = subjectAsset(
            path: "images/huge.tif",
            byteSize: declaredSize,
            sourceSHA256: String(repeating: "a", count: 64)
        )
        let package = try makePackage(handoff: nil, subjectAssets: [declaration])
        defer { try? FileManager.default.removeItem(at: package) }
        let assetURL = package.appendingPathComponent("images/huge.tif")
        try FileManager.default.createDirectory(
            at: assetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: assetURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: assetURL)
        try handle.truncate(atOffset: UInt64(declaredSize + 1))
        try handle.close()
        var checksums = try JSONSerialization.jsonObject(
            with: Data(contentsOf: package.appendingPathComponent("checksums.json"))
        ) as! [String: String]
        checksums["images/huge.tif"] = String(repeating: "a", count: 64)
        try jsonData(checksums).write(to: package.appendingPathComponent("checksums.json"))

        XCTAssertThrowsError(try Brain3DPlanImportService().loadPackage(at: package)) { error in
            XCTAssertTrue(error.localizedDescription.contains("byte size"))
        }
    }

    private func assertUnknownFieldRejected(
        _ mutate: (inout [String: Any]) -> Void
    ) throws {
        var handoff = try makeValidHandoff()
        mutate(&handoff)
        try refreshNestedDigests(&handoff)
        let package = try makePackage(handoff: handoff)
        defer { try? FileManager.default.removeItem(at: package) }
        XCTAssertThrowsError(try Brain3DPlanImportService().loadPackage(at: package))
    }

    private func makeValidHandoff() throws -> [String: Any] {
        let point: (Int, Int, Int) -> [String: Any] = { ap, dv, ml in
            [
                "ap_um": ap, "dv_um": dv, "ml_um": ml,
                "frame_id": "BRAINGLOBE_PHYSICAL_ASR_UM",
            ]
        }
        var shank: [String: Any] = [
            "shank_id": "0",
            "surface_entry": point(100, 200, 300),
            "tip": point(100, 1_200, 300),
            "proximal_end": point(100, 200, 300),
            "total_length_um": 1_000,
            "width_um": 70,
            "thickness_um": 24,
        ]
        shank["shank_sha256"] = try contentDigest(shank)
        let axis: (Int, Int, Int) -> [String: Any] = { ap, ml, dv in
            [
                "ap": ap, "ml": ml, "dv": dv, "unoriented": false,
                "frame_id": "BRAINGLOBE_PHYSICAL_ASR_AP_ML_DV",
                "component_order": ["AP", "ML", "DV"],
            ]
        }
        let surfacePoint: [String: Any] = [
            "atlas_key": "allen_mouse_25um", "atlas_version": "1.2",
            "ap_um": 6_500, "dv_um": 200, "ml_um": 5_700,
            "frame_id": "BRAINGLOBE_PHYSICAL_ASR_UM",
        ]
        let bregma: [String: Any] = [
            "reference_id": "reference", "atlas_key": "allen_mouse_25um",
            "atlas_version": "1.2", "frame_id": "BRAINGLOBE_PHYSICAL_ASR_UM",
            "component_order": ["AP", "DV", "ML"], "units": "micrometre",
            "ap_um": 6_500, "dv_um": 200, "ml_um": 5_700,
            "source_title": "fixture", "source_url": "https://example.test/reference",
            "source_revision": "v1", "source_sha256": String(repeating: "d", count: 64),
            "retrieved_on": "2026-08-01", "limitation": "test fixture only",
        ]
        let controls: [String: Any] = [
            "mode": "ATLAS_SURFACE_AP_ML_BIPLANAR", "bregma_reference": bregma,
            "insertion_ap_mm": 0, "insertion_ml_mm": 0, "surface_depth_mm": 1,
            "sagittal_angle_deg": 0, "mediolateral_angle_deg": 0,
            "probe_layout_rotation_deg": 0, "surface_entry_physical": surfacePoint,
            "surface_dv_index": 8, "surface_dv_resolution_um": 25,
            "annotation_source": "fixture", "annotation_sha256": String(repeating: "b", count: 64),
            "surface_definition_version": "first-annotated-voxel-superior-boundary-v1",
            "ap_sign_convention": "AP positive anterior; AP negative posterior/back",
            "ml_sign_convention": "ML positive animal right; ML negative animal left",
            "depth_convention": "positive path length from the resolved atlas brain-surface entry",
            "angle_convention": "zero is deep/ventral; positive advances anterior-to-posterior; negative advances posterior-to-anterior",
            "layout_convention": "0 degrees uses axial rotation -90; 90 degrees uses axial rotation 0; rotations are about the final inward trajectory from the projected +ML reference",
            "mediolateral_angle_convention": "zero is deep/ventral; positive advances lateral-to-medial within the insertion hemisphere; negative advances medial-to-lateral",
            "angle_parameterization": "independent sagittal and hemisphere-relative mediolateral projected tilts normalized to Euclidean path length",
            "mediolateral_hemisphere_convention": "hemisphere derives from insertion ML sign; nonzero mediolateral tilt is invalid at ML zero",
        ]
        var snapshot: [String: Any] = [
            "insertion_snapshot_id": "33333333-3333-4333-8333-333333333333",
            "plan_ref": [
                "plan_id": "44444444-4444-4444-8444-444444444444", "plan_version": 1,
                "plan_input_sha256": String(repeating: "e", count: 64),
                "planning_algorithm_version": "pinpoint-atlas-surface-ap-ml-depth-biplanar-v5",
            ],
            "placement_id": "55555555-5555-4555-8555-555555555555",
            "placement_sha256": String(repeating: "f", count: 64),
            "surface_controls": controls, "name": "Insertion 1", "subject_id": "ML-2026-0001",
            "probe_model": ["model_id": "NP2003", "model_version": "1"],
            "atlas_metadata_sha256": String(repeating: "a", count: 64),
            "inward_axis": axis(0, 0, 1), "lateral_axis": axis(0, 1, 0),
            "normal_axis": axis(-1, 0, 0), "planned_shanks": [shank],
            "usable_for_navigation": false,
        ]
        snapshot["snapshot_sha256"] = try contentDigest(snapshot)
        var roi: [String: Any] = [
            "roi_set_id": "66666666-6666-4666-8666-666666666666", "name": "ROI",
            "scope": "global", "insertion_snapshot_ids": [],
            "allen_structures": [["structure_id": 500, "include_descendants": true]],
            "asr_boxes": [[
                "box_id": "77777777-7777-4777-8777-777777777777", "label": "Box",
                "minimum": point(0, 0, 0), "maximum": point(1_000, 1_000, 1_000),
                "boundary_rule": "minimum-inclusive-maximum-exclusive",
            ]],
        ]
        roi["roi_set_sha256"] = try contentDigest(roi)
        var handoff: [String: Any] = [
            "schema_version": 1, "handoff_id": "22222222-2222-4222-8222-222222222222",
            "created_at": "2026-08-01T12:00:00Z",
            "project": [
                "project_uuid": "11111111-1111-4111-8111-111111111111", "project_revision": 7,
                "project_schema_version": 10, "application_version": "1.0", "title": "Fixture",
            ],
            "subject": ["subject_id": "ML-2026-0001"],
            "atlas": atlasObject(versionKey: "atlas_version"),
            "roi_sets": [roi], "insertion_snapshots": [snapshot],
            "usable_for_navigation": false,
        ]
        handoff["handoff_sha256"] = try contentDigest(handoff)
        return handoff
    }

    private func refreshNestedDigests(_ handoff: inout [String: Any]) throws {
        var rois = handoff["roi_sets"] as! [[String: Any]]
        for index in rois.indices {
            try refreshDigest(&rois[index], field: "roi_set_sha256")
        }
        handoff["roi_sets"] = rois

        var snapshots = handoff["insertion_snapshots"] as! [[String: Any]]
        for index in snapshots.indices {
            var shanks = snapshots[index]["planned_shanks"] as! [[String: Any]]
            for shankIndex in shanks.indices {
                try refreshDigest(&shanks[shankIndex], field: "shank_sha256")
            }
            snapshots[index]["planned_shanks"] = shanks
            try refreshDigest(&snapshots[index], field: "snapshot_sha256")
        }
        handoff["insertion_snapshots"] = snapshots
        try refreshDigest(&handoff, field: "handoff_sha256")
    }

    private func refreshDigest(_ object: inout [String: Any], field: String) throws {
        object.removeValue(forKey: field)
        object[field] = try contentDigest(object)
    }

    private func makePackage(
        handoff: [String: Any]?,
        subjectAssets: [[String: Any]] = [],
        assetFiles: [String: Data] = [:],
        extraFiles: [String: Data] = [:]
    ) throws -> URL {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("brain3d-strict-\(UUID().uuidString).mouseplan", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let members: [String: Any] = [
            "project.json": [
                "schema_version": 10,
                "project_uuid": "11111111-1111-4111-8111-111111111111",
                "project_revision": 7,
                "subject_id": "ML-2026-0001",
                "subject_vascular_images": subjectAssets,
            ],
            "atlas.json": atlasObject(versionKey: "atlas_package_version"),
            "regions.json": ["regions": []],
            "vasculature.json": ["layers": []],
            "histology.json": [
                "schema_version": 1,
                "locked_handoffs": handoff.map { [$0] } ?? [],
                "brainbuilder_evidence": [],
            ],
        ]
        var checksums: [String: String] = [:]
        for (name, object) in members {
            let data = try jsonData(object)
            try data.write(to: package.appendingPathComponent(name))
            checksums[name] = sha256(data)
        }
        for (name, data) in assetFiles.merging(extraFiles, uniquingKeysWith: { _, rhs in rhs }) {
            let url = package.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url)
            checksums[name] = sha256(data)
        }
        try jsonData(checksums).write(to: package.appendingPathComponent("checksums.json"))
        return package
    }

    private func atlasObject(versionKey: String) -> [String: Any] {
        var atlas: [String: Any] = [
            "atlas_key": "allen_mouse_25um",
            versionKey: "1.2",
            "standardized_orientation": "asr",
            "resolution_um": [25, 25, 25],
            "shape_voxels": [528, 320, 456],
        ]
        if versionKey == "atlas_version" {
            atlas["atlas_metadata_sha256"] = String(repeating: "a", count: 64)
            atlas["annotation_sha256"] = String(repeating: "b", count: 64)
            atlas["ontology_sha256"] = String(repeating: "c", count: 64)
            atlas["coordinate_frame"] = "BRAINGLOBE_PHYSICAL_ASR_UM"
            atlas["coordinate_order"] = ["AP", "DV", "ML"]
            atlas["origin"] = "atlas-anterior-superior-right-voxel-corner"
            atlas["positive_directions"] = ["posterior", "inferior", "left"]
        } else {
            atlas["metadata_sha256"] = String(repeating: "a", count: 64)
        }
        return atlas
    }

    private func subjectAsset(path: String, data: Data) -> [String: Any] {
        subjectAsset(path: path, byteSize: data.count, sourceSHA256: sha256(data))
    }

    private func subjectAsset(
        path: String,
        byteSize: Int,
        sourceSHA256: String
    ) -> [String: Any] {
        [
            "image_uuid": "88888888-8888-4888-8888-888888888888",
            "original_name": "subject.png",
            "project_relative_path": path,
            "source_sha256": sourceSHA256,
            "byte_size": byteSize,
            "image_format": "png",
            "width_px": 1,
            "height_px": 1,
            "frame_count": 1,
            "pixel_size_x_um": NSNull(),
            "pixel_size_y_um": NSNull(),
            "imported_at": "2026-08-01T12:00:00Z",
            "coordinate_frame": "IMAGE_PIXEL_COLUMN_ROW",
            "coordinate_note": "fixture",
            "subject_specific": true,
        ]
    }

    private func contentDigest(_ object: [String: Any]) throws -> String {
        sha256(try jsonData(object))
    }

    private func jsonData(_ value: Any) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
