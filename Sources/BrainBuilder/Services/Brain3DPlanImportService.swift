import CryptoKit
import Foundation

struct Brain3DPlanImportService {
    static let maximumHistologyDocumentBytes = 32 * 1024 * 1024
    static let maximumSubjectAssetCount = 128
    static let maximumSubjectAssetBytes = 512 * 1024 * 1024

    private static let memberMaximumBytes: [String: Int] = [
        "project.json": 128 * 1024 * 1024,
        "atlas.json": 2 * 1024 * 1024,
        "regions.json": 64 * 1024 * 1024,
        "vasculature.json": 16 * 1024 * 1024,
        "histology.json": maximumHistologyDocumentBytes,
    ]
    private static let maximumPackageBytes = memberMaximumBytes.values.reduce(256 * 1024, +)
        + maximumSubjectAssetCount * maximumSubjectAssetBytes

    private let fileManager = FileManager.default
    private let requiredMembers: Set<String> = [
        "project.json",
        "atlas.json",
        "regions.json",
        "vasculature.json",
        "histology.json",
    ]

    private struct DeclaredSubjectAsset {
        var byteSize: Int
        var sourceSHA256: String
    }

    func loadPackage(at packageURL: URL) throws -> Brain3DPlanImport {
        let package = packageURL.standardizedFileURL
        guard package.pathExtension == "mouseplan" else {
            throw Brain3DIntegrationError.invalidPackage("Expected a .mouseplan directory package")
        }
        let packageValues = try package.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey,
        ])
        guard packageValues.isDirectory == true, packageValues.isSymbolicLink != true else {
            throw Brain3DIntegrationError.invalidPackage("Package must be a real directory, not a symlink")
        }

        let checksumsURL = package.appendingPathComponent("checksums.json", isDirectory: false)
        let checksumData = try boundedRegularFile(checksumsURL, maximumBytes: 256 * 1024)
        try StrictJSONDuplicateKeyScanner.validate(checksumData)
        let checksums: [String: String]
        do {
            checksums = try JSONDecoder().decode([String: String].self, from: checksumData)
        } catch {
            throw Brain3DIntegrationError.invalidPackage("checksums.json is not a string-to-string object")
        }
        let checksumNames = Set(checksums.keys)
        guard requiredMembers.isSubset(of: checksumNames) else {
            throw Brain3DIntegrationError.invalidPackage(
                "Schema-10 package is missing one or more required checksummed members"
            )
        }
        guard checksums.count <= requiredMembers.count + Self.maximumSubjectAssetCount else {
            throw Brain3DIntegrationError.invalidPackage("Package contains too many checksummed files")
        }
        for (relativePath, expectedHash) in checksums {
            try validateRelativePath(relativePath)
            guard validSHA256(expectedHash) else {
                throw Brain3DIntegrationError.invalidPackage("Invalid SHA-256 for \(relativePath)")
            }
        }

        let actualFileSizes = try regularPackageFileSizes(package)
        guard Set(actualFileSizes.keys).subtracting(["checksums.json"]) == checksumNames else {
            throw Brain3DIntegrationError.invalidPackage(
                "Checksums must name every regular package file exactly once"
            )
        }

        let projectData = try boundedRegularFile(
            package.appendingPathComponent("project.json"),
            maximumBytes: Self.memberMaximumBytes["project.json"]!
        )
        try StrictJSONDuplicateKeyScanner.validate(projectData)
        guard sha256Data(projectData) == checksums["project.json"] else {
            throw Brain3DIntegrationError.checksumMismatch("project.json")
        }
        let projectObject = try jsonObject(projectData, name: "project.json")
        let subjectAssets = try declaredSubjectAssets(projectObject)
        let allowedMembers = requiredMembers.union(subjectAssets.keys)
        guard checksumNames == allowedMembers else {
            throw Brain3DIntegrationError.invalidPackage(
                "Checksums must contain exactly the schema-10 members and declared subject assets"
            )
        }
        var totalBytes = 0
        for (relativePath, size) in actualFileSizes {
            let maximum: Int
            if relativePath == "checksums.json" {
                maximum = 256 * 1024
            } else if let fixedMaximum = Self.memberMaximumBytes[relativePath] {
                maximum = fixedMaximum
            } else if let asset = subjectAssets[relativePath] {
                maximum = min(Self.maximumSubjectAssetBytes, asset.byteSize)
                guard size == asset.byteSize else {
                    throw Brain3DIntegrationError.invalidPackage(
                        "Declared byte size does not match \(relativePath)"
                    )
                }
            } else {
                throw Brain3DIntegrationError.invalidPackage("Undeclared package member \(relativePath)")
            }
            guard size >= 0, size <= maximum,
                  totalBytes <= Self.maximumPackageBytes - size else {
                throw Brain3DIntegrationError.invalidPackage("Invalid or oversized member \(relativePath)")
            }
            totalBytes += size
        }
        for (relativePath, expectedHash) in checksums where relativePath != "project.json" {
            let fileURL = package.appendingPathComponent(relativePath, isDirectory: false)
            let expectedSize = actualFileSizes[relativePath]!
            let maximum = Self.memberMaximumBytes[relativePath]
                ?? subjectAssets[relativePath]!.byteSize
            let actualHash = try sha256RegularFile(
                fileURL,
                expectedBytes: expectedSize,
                maximumBytes: maximum
            )
            guard actualHash == expectedHash else {
                throw Brain3DIntegrationError.checksumMismatch(relativePath)
            }
            if let asset = subjectAssets[relativePath], actualHash != asset.sourceSHA256 {
                throw Brain3DIntegrationError.checksumMismatch(
                    "\(relativePath) does not match its project.json source_sha256"
                )
            }
        }

        let atlasData = try boundedRegularFile(
            package.appendingPathComponent("atlas.json"),
            maximumBytes: Self.memberMaximumBytes["atlas.json"]!
        )
        let histologyData = try boundedRegularFile(
            package.appendingPathComponent("histology.json"),
            maximumBytes: Self.maximumHistologyDocumentBytes
        )
        for data in [projectData, atlasData, histologyData] {
            try StrictJSONDuplicateKeyScanner.validate(data)
        }
        let atlasObject = try jsonObject(atlasData, name: "atlas.json")
        let histologyObject = try jsonObject(histologyData, name: "histology.json")

        guard integer(projectObject["schema_version"]) == 10 else {
            throw Brain3DIntegrationError.unsupportedSchema(".mouseplan project schema must be 10")
        }
        guard let projectID = projectObject["project_uuid"] as? String,
              UUID(uuidString: projectID) != nil,
              let projectRevision = integer(projectObject["project_revision"]),
              projectRevision >= 0,
              let subjectID = projectObject["subject_id"] as? String,
              !subjectID.isEmpty else {
            throw Brain3DIntegrationError.invalidPackage(
                "project.json requires project_uuid, nonnegative revision, and subject_id"
            )
        }
        try validateAtlasObject(atlasObject)
        guard Set(histologyObject.keys) == [
            "schema_version", "locked_handoffs", "brainbuilder_evidence",
        ], integer(histologyObject["schema_version"]) == 1 else {
            throw Brain3DIntegrationError.unsupportedSchema(
                "histology.json must contain exactly schema_version=1, locked_handoffs, brainbuilder_evidence"
            )
        }
        guard let rawHandoffs = histologyObject["locked_handoffs"] as? [[String: Any]],
              let rawEvidence = histologyObject["brainbuilder_evidence"] as? [Any] else {
            throw Brain3DIntegrationError.invalidPackage("Histology handoff/evidence members must be arrays")
        }
        guard rawHandoffs.count <= 32, rawEvidence.count <= 32 else {
            throw Brain3DIntegrationError.invalidPackage(
                "histology.json exceeds the 32-handoff/evidence-record limits"
            )
        }

        let decoder = JSONDecoder()
        let document: Brain3DHistologyDocument
        do {
            document = try decoder.decode(Brain3DHistologyDocument.self, from: histologyData)
        } catch {
            throw Brain3DIntegrationError.invalidPackage("Could not decode strict histology contract: \(error)")
        }
        guard document.lockedHandoffs.count == rawHandoffs.count else {
            throw Brain3DIntegrationError.invalidPackage("Decoded handoff count changed")
        }
        for (index, pair) in zip(rawHandoffs, document.lockedHandoffs).enumerated() {
            try validateHandoff(
                pair.0,
                typed: pair.1,
                index: index,
                projectID: projectID,
                projectRevision: projectRevision,
                subjectID: subjectID,
                atlasObject: atlasObject
            )
        }
        return Brain3DPlanImport(
            packageURL: package,
            projectID: projectID,
            projectRevision: projectRevision,
            subjectID: subjectID,
            handoffs: document.lockedHandoffs,
            histologySHA256: checksums["histology.json"]!
        )
    }

    func makeContext(
        from imported: Brain3DPlanImport,
        handoff: Brain3DHistologyHandoff,
        datasetSubjectID: String?,
        datasetFingerprint: String,
        rebindAudit: Brain3DSubjectRebindAudit? = nil
    ) throws -> Brain3DContext {
        guard imported.handoffs.contains(handoff),
              let handoffID = handoff.handoffID,
              let handoffHash = handoff.handoffSHA256,
              let planSubjectID = handoff.subjectID,
              let projectID = handoff.sourceProjectID,
              let projectRevision = handoff.sourceProjectRevision else {
            throw Brain3DIntegrationError.invalidPackage("Selected handoff lacks immutable identity fields")
        }
        guard !datasetFingerprint.isEmpty else {
            throw Brain3DIntegrationError.invalidPackage("Dataset fingerprint is required")
        }
        let binding: Brain3DSubjectBinding
        if datasetSubjectID == planSubjectID {
            binding = Brain3DSubjectBinding(
                state: .exactMatch,
                planSubjectId: planSubjectID,
                datasetSubjectId: planSubjectID,
                datasetFingerprint: datasetFingerprint
            )
        } else {
            guard let datasetSubjectID,
                  let audit = rebindAudit,
                  audit.planSubjectId == planSubjectID,
                  audit.datasetSubjectId == datasetSubjectID,
                  audit.datasetFingerprint == datasetFingerprint,
                  audit.handoffSha256 == handoffHash,
                  !audit.operatorLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !audit.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Brain3DIntegrationError.subjectBindingRequired(
                    planSubjectID: planSubjectID,
                    datasetSubjectID: datasetSubjectID
                )
            }
            binding = Brain3DSubjectBinding(
                state: .explicitAliasRebind,
                planSubjectId: planSubjectID,
                datasetSubjectId: datasetSubjectID,
                datasetFingerprint: datasetFingerprint,
                rebindAudit: audit
            )
        }
        return Brain3DContext(
            handoff: handoff,
            priorReceipt: Brain3DPriorReceipt(
                handoffId: handoffID,
                handoffSha256: handoffHash,
                sourceProjectId: projectID,
                sourceProjectRevision: projectRevision,
                sourceSubjectId: planSubjectID
            ),
            subjectBinding: binding,
            blindReviewLocked: false
        )
    }

    private func validateHandoff(
        _ object: [String: Any],
        typed: Brain3DHistologyHandoff,
        index: Int,
        projectID: String,
        projectRevision: Int,
        subjectID: String,
        atlasObject: [String: Any]
    ) throws {
        let expectedKeys: Set<String> = [
            "schema_version", "handoff_id", "created_at", "project", "subject", "atlas",
            "roi_sets", "insertion_snapshots", "handoff_sha256", "usable_for_navigation",
        ]
        guard Set(object.keys) == expectedKeys,
              integer(object["schema_version"]) == 1,
              object["usable_for_navigation"] as? Bool == false,
              let handoffID = object["handoff_id"] as? String,
              UUID(uuidString: handoffID) != nil,
              let storedDigest = object["handoff_sha256"] as? String,
              storedDigest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              let createdAt = object["created_at"] as? String,
              createdAt.range(
                  of: #"T.*(Z|[+-][0-9]{2}:[0-9]{2})$"#,
                  options: .regularExpression
              ) != nil,
              let handoffProject = object["project"] as? [String: Any],
              let handoffSubject = object["subject"] as? [String: Any],
              let handoffAtlas = object["atlas"] as? [String: Any],
              let roiSets = object["roi_sets"] as? [[String: Any]],
              let insertionSnapshots = object["insertion_snapshots"] as? [[String: Any]] else {
            throw Brain3DIntegrationError.invalidPackage("locked_handoffs[\(index)] has invalid keys or types")
        }
        try validateHandoffProject(
            handoffProject,
            projectID: projectID,
            maximumRevision: projectRevision,
            path: "locked_handoffs[\(index)].project"
        )
        try validateHandoffSubject(
            handoffSubject,
            subjectID: subjectID,
            path: "locked_handoffs[\(index)].subject"
        )
        let insertionIDs = try validateInsertionSnapshots(
            insertionSnapshots,
            subjectID: subjectID,
            atlasMetadataSHA256: handoffAtlas["atlas_metadata_sha256"] as? String,
            path: "locked_handoffs[\(index)].insertion_snapshots"
        )
        try validateROISets(
            roiSets,
            insertionIDs: insertionIDs,
            path: "locked_handoffs[\(index)].roi_sets"
        )
        guard handoffProject["project_uuid"] as? String == projectID,
              handoffSubject["subject_id"] as? String == subjectID else {
            throw Brain3DIntegrationError.invalidPackage(
                "locked_handoffs[\(index)] does not belong to this project/subject"
            )
        }
        try validateHandoffAtlas(handoffAtlas, packageAtlas: atlasObject)
        var digestObject = object
        digestObject.removeValue(forKey: "handoff_sha256")
        let actualDigest = sha256Data(try canonicalJSONData(digestObject))
        guard actualDigest == storedDigest, typed.handoffSHA256 == storedDigest else {
            throw Brain3DIntegrationError.checksumMismatch("locked_handoffs[\(index)].handoff_sha256")
        }
    }

    private func validateHandoffProject(
        _ project: [String: Any],
        projectID: String,
        maximumRevision: Int,
        path: String
    ) throws {
        let expectedKeys: Set<String> = [
            "project_uuid", "project_revision", "project_schema_version",
            "application_version", "title",
        ]
        guard Set(project.keys) == expectedKeys,
              project["project_uuid"] as? String == projectID,
              let revision = integer(project["project_revision"]),
              (0...maximumRevision).contains(revision),
              integer(project["project_schema_version"]) == 10,
              visibleString(project["application_version"], maximumLength: 100) != nil,
              visibleString(project["title"], maximumLength: 200) != nil else {
            throw Brain3DIntegrationError.invalidPackage("\(path) has an invalid exact schema")
        }
    }

    private func validateHandoffSubject(
        _ subject: [String: Any],
        subjectID: String,
        path: String
    ) throws {
        guard Set(subject.keys) == ["subject_id"],
              subject["subject_id"] as? String == subjectID,
              visibleString(subject["subject_id"], maximumLength: 200) != nil else {
            throw Brain3DIntegrationError.invalidPackage("\(path) has an invalid exact schema")
        }
    }

    private func validateROISets(
        _ roiSets: [[String: Any]],
        insertionIDs: Set<String>,
        path: String
    ) throws {
        guard (1...64).contains(roiSets.count) else {
            throw Brain3DIntegrationError.invalidPackage("\(path) must contain 1...64 ROI sets")
        }
        let expectedKeys: Set<String> = [
            "roi_set_id", "name", "scope", "insertion_snapshot_ids",
            "allen_structures", "asr_boxes", "roi_set_sha256",
        ]
        var seenIDs: Set<String> = []
        var memberCount = 0
        for (index, roi) in roiSets.enumerated() {
            let itemPath = "\(path)[\(index)]"
            guard Set(roi.keys) == expectedKeys,
                  let roiID = uuidString(roi["roi_set_id"]),
                  seenIDs.insert(roiID).inserted,
                  visibleString(roi["name"], maximumLength: 200) != nil,
                  let scope = roi["scope"] as? String,
                  ["global", "insertion"].contains(scope),
                  let scopedIDs = roi["insertion_snapshot_ids"] as? [String],
                  scopedIDs.count <= 32,
                  Set(scopedIDs).count == scopedIDs.count,
                  scopedIDs.allSatisfy({ UUID(uuidString: $0) != nil }),
                  let structures = roi["allen_structures"] as? [[String: Any]],
                  structures.count <= 128,
                  let boxes = roi["asr_boxes"] as? [[String: Any]],
                  boxes.count <= 64,
                  !structures.isEmpty || !boxes.isEmpty,
                  validSHA256(roi["roi_set_sha256"]) else {
                throw Brain3DIntegrationError.invalidPackage("\(itemPath) has an invalid exact schema")
            }
            guard (scope == "global" && scopedIDs.isEmpty)
                    || (scope == "insertion" && !scopedIDs.isEmpty
                        && Set(scopedIDs).isSubset(of: insertionIDs)) else {
                throw Brain3DIntegrationError.invalidPackage("\(itemPath) has an invalid insertion scope")
            }
            memberCount += structures.count + boxes.count
            guard memberCount <= 256 else {
                throw Brain3DIntegrationError.invalidPackage("\(path) exceeds the 256-member limit")
            }
            var structureIDs: Set<Int> = []
            for (memberIndex, structure) in structures.enumerated() {
                guard Set(structure.keys) == ["structure_id", "include_descendants"],
                      let structureID = integer(structure["structure_id"]), structureID > 0,
                      structure["include_descendants"] is Bool,
                      structureIDs.insert(structureID).inserted else {
                    throw Brain3DIntegrationError.invalidPackage(
                        "\(itemPath).allen_structures[\(memberIndex)] has an invalid exact schema"
                    )
                }
            }
            var boxIDs: Set<String> = []
            for (memberIndex, box) in boxes.enumerated() {
                let boxPath = "\(itemPath).asr_boxes[\(memberIndex)]"
                guard Set(box.keys) == [
                    "box_id", "label", "minimum", "maximum", "boundary_rule",
                ], let boxID = uuidString(box["box_id"]), boxIDs.insert(boxID).inserted,
                   visibleString(box["label"], maximumLength: 200) != nil,
                   box["boundary_rule"] as? String == "minimum-inclusive-maximum-exclusive",
                   let minimum = try histologyPoint(box["minimum"], path: "\(boxPath).minimum"),
                   let maximum = try histologyPoint(box["maximum"], path: "\(boxPath).maximum"),
                   minimum.0 < maximum.0, minimum.1 < maximum.1, minimum.2 < maximum.2 else {
                    throw Brain3DIntegrationError.invalidPackage("\(boxPath) has an invalid exact schema")
                }
            }
            try validateEmbeddedDigest(roi, field: "roi_set_sha256", path: itemPath)
        }
    }

    private func validateInsertionSnapshots(
        _ snapshots: [[String: Any]],
        subjectID: String,
        atlasMetadataSHA256: String?,
        path: String
    ) throws -> Set<String> {
        guard (1...32).contains(snapshots.count), validSHA256(atlasMetadataSHA256) else {
            throw Brain3DIntegrationError.invalidPackage("\(path) has invalid bounds or atlas identity")
        }
        let expectedKeys: Set<String> = [
            "insertion_snapshot_id", "plan_ref", "placement_id", "placement_sha256",
            "surface_controls", "name", "subject_id", "probe_model",
            "atlas_metadata_sha256", "inward_axis", "lateral_axis", "normal_axis",
            "planned_shanks", "snapshot_sha256", "usable_for_navigation",
        ]
        var insertionIDs: Set<String> = []
        var totalShanks = 0
        for (index, snapshot) in snapshots.enumerated() {
            let itemPath = "\(path)[\(index)]"
            guard Set(snapshot.keys) == expectedKeys,
                  let insertionID = uuidString(snapshot["insertion_snapshot_id"]),
                  insertionIDs.insert(insertionID).inserted,
                  uuidString(snapshot["placement_id"]) != nil,
                  validSHA256(snapshot["placement_sha256"]),
                  visibleString(snapshot["name"], maximumLength: 200) != nil,
                  snapshot["subject_id"] as? String == subjectID,
                  snapshot["atlas_metadata_sha256"] as? String == atlasMetadataSHA256,
                  snapshot["usable_for_navigation"] as? Bool == false,
                  validSHA256(snapshot["snapshot_sha256"]),
                  let plan = snapshot["plan_ref"] as? [String: Any],
                  let probe = snapshot["probe_model"] as? [String: Any],
                  let controls = snapshot["surface_controls"] as? [String: Any],
                  let inward = snapshot["inward_axis"] as? [String: Any],
                  let lateral = snapshot["lateral_axis"] as? [String: Any],
                  let normal = snapshot["normal_axis"] as? [String: Any],
                  let shanks = snapshot["planned_shanks"] as? [[String: Any]],
                  (1...32).contains(shanks.count) else {
                throw Brain3DIntegrationError.invalidPackage("\(itemPath) has an invalid exact schema")
            }
            let algorithm = try validatePlanReference(plan, path: "\(itemPath).plan_ref")
            try validateProbeModel(probe, path: "\(itemPath).probe_model")
            let controlMode = try validateSurfaceControls(
                controls,
                path: "\(itemPath).surface_controls"
            )
            let expectedAlgorithm = controlMode == "ATLAS_SURFACE_AP_ML"
                ? "pinpoint-atlas-surface-ap-ml-depth-v4"
                : "pinpoint-atlas-surface-ap-ml-depth-biplanar-v5"
            guard algorithm == expectedAlgorithm else {
                throw Brain3DIntegrationError.invalidPackage(
                    "\(itemPath) controls do not match the planning algorithm"
                )
            }
            let axes = try [inward, lateral, normal].enumerated().map { axisIndex, axis in
                try unitAxis(axis, path: "\(itemPath).axis[\(axisIndex)]")
            }
            guard axes.allSatisfy({ !$0.unoriented }), axesAreOrthonormal(axes) else {
                throw Brain3DIntegrationError.invalidPackage("\(itemPath) basis is not oriented orthonormal")
            }
            totalShanks += shanks.count
            guard totalShanks <= 128 else {
                throw Brain3DIntegrationError.invalidPackage("\(path) exceeds the 128-shank limit")
            }
            var shankIDs: Set<String> = []
            for (shankIndex, shank) in shanks.enumerated() {
                try validateShank(
                    shank,
                    seenIDs: &shankIDs,
                    path: "\(itemPath).planned_shanks[\(shankIndex)]"
                )
            }
            try validateEmbeddedDigest(snapshot, field: "snapshot_sha256", path: itemPath)
        }
        return insertionIDs
    }

    private func validatePlanReference(_ plan: [String: Any], path: String) throws -> String {
        guard Set(plan.keys) == [
            "plan_id", "plan_version", "plan_input_sha256", "planning_algorithm_version",
        ], uuidString(plan["plan_id"]) != nil,
           let version = integer(plan["plan_version"]), version > 0,
           validSHA256(plan["plan_input_sha256"]),
           let algorithm = plan["planning_algorithm_version"] as? String,
           [
               "pinpoint-atlas-surface-ap-ml-depth-v4",
               "pinpoint-atlas-surface-ap-ml-depth-biplanar-v5",
           ].contains(algorithm) else {
            throw Brain3DIntegrationError.invalidPackage("\(path) has an invalid exact schema")
        }
        return algorithm
    }

    private func validateProbeModel(_ probe: [String: Any], path: String) throws {
        guard Set(probe.keys) == ["model_id", "model_version"],
              visibleString(probe["model_id"], maximumLength: 200) != nil,
              visibleString(probe["model_version"], maximumLength: 100) != nil else {
            throw Brain3DIntegrationError.invalidPackage("\(path) has an invalid exact schema")
        }
    }

    private func validateSurfaceControls(
        _ controls: [String: Any],
        path: String
    ) throws -> String {
        let baseKeys: Set<String> = [
            "mode", "bregma_reference", "insertion_ap_mm", "insertion_ml_mm",
            "surface_depth_mm", "sagittal_angle_deg", "probe_layout_rotation_deg",
            "surface_entry_physical", "surface_dv_index", "surface_dv_resolution_um",
            "annotation_source", "annotation_sha256", "surface_definition_version",
            "ap_sign_convention", "ml_sign_convention", "depth_convention",
            "angle_convention", "layout_convention",
        ]
        guard let mode = controls["mode"] as? String,
              ["ATLAS_SURFACE_AP_ML", "ATLAS_SURFACE_AP_ML_BIPLANAR"].contains(mode) else {
            throw Brain3DIntegrationError.invalidPackage("\(path).mode is invalid")
        }
        let biplanarKeys: Set<String> = [
            "mediolateral_angle_deg", "mediolateral_angle_convention",
            "angle_parameterization", "mediolateral_hemisphere_convention",
        ]
        let expectedKeys = mode == "ATLAS_SURFACE_AP_ML" ? baseKeys : baseKeys.union(biplanarKeys)
        guard Set(controls.keys) == expectedKeys,
              finiteNumber(controls["insertion_ap_mm"]) != nil,
              let insertionML = finiteNumber(controls["insertion_ml_mm"]),
              let depth = finiteNumber(controls["surface_depth_mm"]), depth > 0,
              let sagittal = finiteNumber(controls["sagittal_angle_deg"]),
              sagittal > -90, sagittal < 90,
              let layout = integer(controls["probe_layout_rotation_deg"]),
              [0, 90].contains(layout),
              let surfaceIndex = integer(controls["surface_dv_index"]), surfaceIndex >= 0,
              let resolution = finiteNumber(controls["surface_dv_resolution_um"]), resolution > 0,
              visibleString(controls["annotation_source"], maximumLength: 500) != nil,
              validSHA256(controls["annotation_sha256"]),
              controls["surface_definition_version"] as? String
                  == "first-annotated-voxel-superior-boundary-v1",
              controls["bregma_reference"] is [String: Any],
              controls["surface_entry_physical"] is [String: Any] else {
            throw Brain3DIntegrationError.invalidPackage("\(path) has an invalid exact schema")
        }
        try validateBregmaReference(controls["bregma_reference"]!, path: "\(path).bregma_reference")
        try validateBrainGlobePoint(
            controls["surface_entry_physical"]!,
            path: "\(path).surface_entry_physical"
        )
        if mode == "ATLAS_SURFACE_AP_ML_BIPLANAR" {
            guard let mediolateral = finiteNumber(controls["mediolateral_angle_deg"]),
                  mediolateral > -90, mediolateral < 90,
                  insertionML != 0 || mediolateral == 0 else {
                throw Brain3DIntegrationError.invalidPackage("\(path) has an invalid ML angle")
            }
        }
        return mode
    }

    private func validateBregmaReference(_ value: Any, path: String) throws {
        let expectedKeys: Set<String> = [
            "reference_id", "atlas_key", "atlas_version", "frame_id", "component_order",
            "units", "ap_um", "dv_um", "ml_um", "source_title", "source_url",
            "source_revision", "source_sha256", "retrieved_on", "limitation",
        ]
        guard let object = value as? [String: Any], Set(object.keys) == expectedKeys,
              visibleString(object["reference_id"], maximumLength: 200) != nil,
              object["atlas_key"] as? String == "allen_mouse_25um",
              object["atlas_version"] as? String == "1.2",
              object["frame_id"] as? String == "BRAINGLOBE_PHYSICAL_ASR_UM",
              object["component_order"] as? [String] == ["AP", "DV", "ML"],
              object["units"] as? String == "micrometre",
              let ap = finiteNumber(object["ap_um"]), ap >= 0,
              let dv = finiteNumber(object["dv_um"]), dv >= 0,
              let ml = finiteNumber(object["ml_um"]), ml >= 0,
              visibleString(object["source_title"], maximumLength: 500) != nil,
              let sourceURL = object["source_url"] as? String, sourceURL.hasPrefix("https://"),
              visibleString(object["source_revision"], maximumLength: 300) != nil,
              validSHA256(object["source_sha256"]),
              object["retrieved_on"] is String,
              visibleString(object["limitation"], maximumLength: 2_000) != nil else {
            throw Brain3DIntegrationError.invalidPackage("\(path) has an invalid exact schema")
        }
    }

    private func validateBrainGlobePoint(_ value: Any, path: String) throws {
        guard let object = value as? [String: Any], Set(object.keys) == [
            "atlas_key", "atlas_version", "ap_um", "dv_um", "ml_um", "frame_id",
        ], object["atlas_key"] as? String == "allen_mouse_25um",
           object["atlas_version"] as? String == "1.2",
           object["frame_id"] as? String == "BRAINGLOBE_PHYSICAL_ASR_UM",
           finiteNumber(object["ap_um"]) != nil,
           finiteNumber(object["dv_um"]) != nil,
           finiteNumber(object["ml_um"]) != nil else {
            throw Brain3DIntegrationError.invalidPackage("\(path) has an invalid exact schema")
        }
    }

    private struct ValidatedUnitAxis {
        var ap: Double
        var ml: Double
        var dv: Double
        var unoriented: Bool
    }

    private func unitAxis(_ axis: [String: Any], path: String) throws -> ValidatedUnitAxis {
        guard Set(axis.keys) == ["ap", "ml", "dv", "unoriented", "frame_id", "component_order"],
              let ap = finiteNumber(axis["ap"]),
              let ml = finiteNumber(axis["ml"]),
              let dv = finiteNumber(axis["dv"]),
              let unoriented = axis["unoriented"] as? Bool,
              axis["frame_id"] as? String == "BRAINGLOBE_PHYSICAL_ASR_AP_ML_DV",
              axis["component_order"] as? [String] == ["AP", "ML", "DV"],
              abs(sqrt(ap * ap + ml * ml + dv * dv) - 1) <= 1e-9 else {
            throw Brain3DIntegrationError.invalidPackage("\(path) has an invalid exact schema")
        }
        return ValidatedUnitAxis(ap: ap, ml: ml, dv: dv, unoriented: unoriented)
    }

    private func axesAreOrthonormal(_ axes: [ValidatedUnitAxis]) -> Bool {
        guard axes.count == 3 else { return false }
        func dot(_ lhs: ValidatedUnitAxis, _ rhs: ValidatedUnitAxis) -> Double {
            lhs.ap * rhs.ap + lhs.ml * rhs.ml + lhs.dv * rhs.dv
        }
        guard abs(dot(axes[0], axes[1])) <= 1e-9,
              abs(dot(axes[0], axes[2])) <= 1e-9,
              abs(dot(axes[1], axes[2])) <= 1e-9 else { return false }
        let cross = (
            axes[0].ml * axes[1].dv - axes[0].dv * axes[1].ml,
            axes[0].dv * axes[1].ap - axes[0].ap * axes[1].dv,
            axes[0].ap * axes[1].ml - axes[0].ml * axes[1].ap
        )
        return abs(cross.0 - axes[2].ap) <= 1e-9
            && abs(cross.1 - axes[2].ml) <= 1e-9
            && abs(cross.2 - axes[2].dv) <= 1e-9
    }

    private func validateShank(
        _ shank: [String: Any],
        seenIDs: inout Set<String>,
        path: String
    ) throws {
        let expectedKeys: Set<String> = [
            "shank_id", "surface_entry", "tip", "proximal_end", "total_length_um",
            "width_um", "thickness_um", "shank_sha256",
        ]
        guard Set(shank.keys) == expectedKeys,
              let shankID = visibleString(shank["shank_id"], maximumLength: 200),
              seenIDs.insert(shankID).inserted,
              let entry = try histologyPoint(shank["surface_entry"], path: "\(path).surface_entry"),
              let tip = try histologyPoint(shank["tip"], path: "\(path).tip"),
              let proximal = try histologyPoint(shank["proximal_end"], path: "\(path).proximal_end"),
              entry != tip,
              let length = finiteNumber(shank["total_length_um"]), length > 0,
              let width = finiteNumber(shank["width_um"]), width > 0,
              let thickness = finiteNumber(shank["thickness_um"]), thickness > 0,
              validSHA256(shank["shank_sha256"]) else {
            throw Brain3DIntegrationError.invalidPackage("\(path) has an invalid exact schema")
        }
        let actualLength = sqrt(
            pow(tip.0 - proximal.0, 2) + pow(tip.1 - proximal.1, 2) + pow(tip.2 - proximal.2, 2)
        )
        guard abs(actualLength - length) <= max(1e-6, length * 1e-10) else {
            throw Brain3DIntegrationError.invalidPackage("\(path) length does not match its geometry")
        }
        try validateEmbeddedDigest(shank, field: "shank_sha256", path: path)
    }

    private func histologyPoint(
        _ value: Any?,
        path: String
    ) throws -> (Double, Double, Double)? {
        guard let point = value as? [String: Any], Set(point.keys) == [
            "ap_um", "dv_um", "ml_um", "frame_id",
        ], point["frame_id"] as? String == "BRAINGLOBE_PHYSICAL_ASR_UM",
           let ap = finiteNumber(point["ap_um"]),
           let dv = finiteNumber(point["dv_um"]),
           let ml = finiteNumber(point["ml_um"]) else {
            throw Brain3DIntegrationError.invalidPackage("\(path) has an invalid exact schema")
        }
        return (ap, dv, ml)
    }

    private func validateEmbeddedDigest(
        _ object: [String: Any],
        field: String,
        path: String
    ) throws {
        guard let expected = object[field] as? String, validSHA256(expected) else {
            throw Brain3DIntegrationError.invalidPackage("\(path).\(field) is invalid")
        }
        var content = object
        content.removeValue(forKey: field)
        guard sha256Data(try canonicalJSONData(content)) == expected else {
            throw Brain3DIntegrationError.checksumMismatch("\(path).\(field)")
        }
    }

    private func uuidString(_ value: Any?) -> String? {
        guard let value = value as? String, UUID(uuidString: value) != nil else { return nil }
        return value
    }

    private func visibleString(_ value: Any?, maximumLength: Int) -> String? {
        guard let value = value as? String,
              value.count <= maximumLength,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private func finiteNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private func validateAtlasObject(_ atlas: [String: Any]) throws {
        guard atlas["atlas_key"] as? String == "allen_mouse_25um",
              atlas["atlas_package_version"] as? String == "1.2",
              atlas["standardized_orientation"] as? String == "asr",
              numericArray(atlas["resolution_um"]) == [25, 25, 25],
              integerArray(atlas["shape_voxels"]) == [528, 320, 456] else {
            throw Brain3DIntegrationError.atlasMismatch(
                "Expected allen_mouse_25um v1.2, ASR, 25um, shape 528×320×456"
            )
        }
    }

    private func validateHandoffAtlas(
        _ atlas: [String: Any],
        packageAtlas: [String: Any]
    ) throws {
        let expectedKeys: Set<String> = [
            "atlas_key", "atlas_version", "atlas_metadata_sha256", "annotation_sha256",
            "ontology_sha256",
            "standardized_orientation", "resolution_um", "shape_voxels", "coordinate_frame",
            "coordinate_order", "origin", "positive_directions",
        ]
        guard Set(atlas.keys) == expectedKeys,
              atlas["atlas_key"] as? String == "allen_mouse_25um",
              atlas["atlas_version"] as? String == "1.2",
              atlas["standardized_orientation"] as? String == "asr",
              atlas["coordinate_frame"] as? String == "BRAINGLOBE_PHYSICAL_ASR_UM",
              atlas["coordinate_order"] as? [String] == ["AP", "DV", "ML"],
              atlas["origin"] as? String == "atlas-anterior-superior-right-voxel-corner",
              atlas["positive_directions"] as? [String] == ["posterior", "inferior", "left"],
              numericArray(atlas["resolution_um"]) == [25, 25, 25],
              integerArray(atlas["shape_voxels"]) == [528, 320, 456],
              atlas["atlas_metadata_sha256"] as? String == packageAtlas["metadata_sha256"] as? String,
              validSHA256(atlas["annotation_sha256"]),
              validSHA256(atlas["ontology_sha256"]) else {
            throw Brain3DIntegrationError.atlasMismatch("Locked handoff atlas identity is inconsistent")
        }
    }

    private func boundedRegularFile(_ url: URL, maximumBytes: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size <= maximumBytes else {
            throw Brain3DIntegrationError.invalidPackage("Invalid or oversized member \(url.lastPathComponent)")
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe, .uncached])
    }

    private func declaredSubjectAssets(
        _ project: [String: Any]
    ) throws -> [String: DeclaredSubjectAsset] {
        guard let rawValue = project["subject_vascular_images"] else { return [:] }
        guard let images = rawValue as? [[String: Any]],
              images.count <= Self.maximumSubjectAssetCount else {
            throw Brain3DIntegrationError.invalidPackage(
                "project.json subject_vascular_images must contain at most 128 objects"
            )
        }
        let expectedKeys: Set<String> = [
            "image_uuid", "original_name", "project_relative_path", "source_sha256",
            "byte_size", "image_format", "width_px", "height_px", "frame_count",
            "pixel_size_x_um", "pixel_size_y_um", "imported_at", "coordinate_frame",
            "coordinate_note", "subject_specific",
        ]
        var result: [String: DeclaredSubjectAsset] = [:]
        for (index, image) in images.enumerated() {
            guard Set(image.keys) == expectedKeys,
                  let relativePath = image["project_relative_path"] as? String,
                  let byteSize = integer(image["byte_size"]),
                  byteSize > 0,
                  byteSize <= Self.maximumSubjectAssetBytes,
                  let sourceSHA256 = image["source_sha256"] as? String,
                  validSHA256(sourceSHA256),
                  image["subject_specific"] as? Bool == true,
                  image["coordinate_frame"] as? String == "IMAGE_PIXEL_COLUMN_ROW" else {
                throw Brain3DIntegrationError.invalidPackage(
                    "subject_vascular_images[\(index)] has an invalid schema or resource receipt"
                )
            }
            try validateRelativePath(relativePath)
            let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
            guard components.count == 2, components[0] == "images",
                  !components[1].isEmpty,
                  result[relativePath] == nil else {
                throw Brain3DIntegrationError.invalidPackage(
                    "Subject assets must be unique direct children of images/"
                )
            }
            result[relativePath] = DeclaredSubjectAsset(
                byteSize: byteSize,
                sourceSHA256: sourceSHA256
            )
        }
        return result
    }

    private func regularPackageFileSizes(_ root: URL) throws -> [String: Int] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ],
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw Brain3DIntegrationError.invalidPackage("Could not enumerate package members")
        }
        var files: [String: Int] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
            guard values.isSymbolicLink != true else {
                throw Brain3DIntegrationError.invalidPackage("Symlink member is forbidden: \(url.lastPathComponent)")
            }
            let rootComponents = root.standardizedFileURL.pathComponents
            let components = url.standardizedFileURL.pathComponents
            guard components.starts(with: rootComponents) else {
                throw Brain3DIntegrationError.invalidPackage("Package member escaped its root")
            }
            let relative = components.dropFirst(rootComponents.count).joined(separator: "/")
            try validateRelativePath(relative)
            if values.isDirectory == true {
                guard relative == "images" else {
                    throw Brain3DIntegrationError.invalidPackage(
                        "Unexpected package directory: \(relative)"
                    )
                }
                continue
            }
            guard values.isRegularFile == true, let fileSize = values.fileSize else {
                throw Brain3DIntegrationError.invalidPackage("Non-regular package member: \(url.lastPathComponent)")
            }
            guard files.updateValue(fileSize, forKey: relative) == nil else {
                throw Brain3DIntegrationError.invalidPackage("Duplicate package path: \(relative)")
            }
            guard files.count <= requiredMembers.count + Self.maximumSubjectAssetCount + 1 else {
                throw Brain3DIntegrationError.invalidPackage("Package contains too many files")
            }
        }
        return files
    }

    private func validateRelativePath(_ value: String) throws {
        let path = NSString(string: value)
        guard !value.isEmpty,
              !path.isAbsolutePath,
              !value.contains("\\"),
              value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              }) else {
            throw Brain3DIntegrationError.invalidPackage("Unsafe relative path: \(value)")
        }
    }

    private func sha256RegularFile(
        _ url: URL,
        expectedBytes: Int,
        maximumBytes: Int
    ) throws -> String {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw Brain3DIntegrationError.invalidPackage("Checksum target must be a regular file")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var bytesRead = 0
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            guard bytesRead <= maximumBytes - data.count,
                  bytesRead <= expectedBytes - data.count else {
                throw Brain3DIntegrationError.invalidPackage(
                    "Checksum target exceeded its declared resource limit"
                )
            }
            bytesRead += data.count
            hasher.update(data: data)
        }
        guard bytesRead == expectedBytes else {
            throw Brain3DIntegrationError.invalidPackage(
                "Checksum target changed size while it was being verified"
            )
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func sha256Data(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func jsonObject(_ data: Data, name: String) throws -> [String: Any] {
        do {
            guard let value = try JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            ) as? [String: Any] else {
                throw Brain3DIntegrationError.invalidPackage("\(name) must contain an object")
            }
            return value
        } catch let error as Brain3DIntegrationError {
            throw error
        } catch {
            throw Brain3DIntegrationError.invalidPackage("Could not decode \(name): \(error)")
        }
    }

    private func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double else { return nil }
        return Int(exactly: double)
    }

    private func numericArray(_ value: Any?) -> [Double]? {
        guard let values = value as? [NSNumber] else { return nil }
        let output = values.map(\.doubleValue)
        return output.allSatisfy(\.isFinite) ? output : nil
    }

    private func integerArray(_ value: Any?) -> [Int]? {
        guard let values = value as? [Any] else { return nil }
        let output = values.compactMap(integer)
        return output.count == values.count ? output : nil
    }

    private func validSHA256(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        return value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }

    private func canonicalJSONData(_ value: Any) throws -> Data {
        var output = ""
        try appendCanonicalJSON(value, to: &output)
        guard let data = output.data(using: .utf8) else {
            throw Brain3DIntegrationError.invalidPackage("Could not encode canonical JSON")
        }
        return data
    }

    private func appendCanonicalJSON(_ value: Any, to output: inout String) throws {
        switch value {
        case let object as [String: Any]:
            output.append("{")
            for (index, key) in object.keys.sorted().enumerated() {
                if index > 0 { output.append(",") }
                output.append(asciiJSONString(key))
                output.append(":")
                try appendCanonicalJSON(object[key]!, to: &output)
            }
            output.append("}")
        case let array as [Any]:
            output.append("[")
            for (index, item) in array.enumerated() {
                if index > 0 { output.append(",") }
                try appendCanonicalJSON(item, to: &output)
            }
            output.append("]")
        case let string as String:
            output.append(asciiJSONString(string))
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                output.append(number.boolValue ? "true" : "false")
            } else {
                let value = number.doubleValue
                guard value.isFinite else {
                    throw Brain3DIntegrationError.invalidPackage("Canonical JSON contains non-finite number")
                }
                output.append(number.stringValue)
            }
        case _ as NSNull:
            output.append("null")
        default:
            throw Brain3DIntegrationError.invalidPackage("Unsupported canonical JSON value")
        }
    }

    private func asciiJSONString(_ value: String) -> String {
        var output = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: output.append("\\\"")
            case 0x5C: output.append("\\\\")
            case 0x08: output.append("\\b")
            case 0x0C: output.append("\\f")
            case 0x0A: output.append("\\n")
            case 0x0D: output.append("\\r")
            case 0x09: output.append("\\t")
            case 0x20...0x7E: output.unicodeScalars.append(scalar)
            case 0...0xFFFF:
                output.append(String(format: "\\u%04x", scalar.value))
            default:
                let value = scalar.value - 0x10000
                let high = 0xD800 + (value >> 10)
                let low = 0xDC00 + (value & 0x3FF)
                output.append(String(format: "\\u%04x\\u%04x", high, low))
            }
        }
        output.append("\"")
        return output
    }
}

private struct StrictJSONDuplicateKeyScanner {
    private let bytes: [UInt8]
    private var index = 0

    static func validate(_ data: Data) throws {
        var scanner = StrictJSONDuplicateKeyScanner(bytes: Array(data))
        try scanner.parseValue()
        scanner.skipWhitespace()
        guard scanner.index == scanner.bytes.count else {
            throw Brain3DIntegrationError.invalidPackage("JSON contains trailing bytes")
        }
    }

    private mutating func parseValue() throws {
        skipWhitespace()
        guard index < bytes.count else { throw malformed() }
        switch bytes[index] {
        case 0x7B: try parseObject()
        case 0x5B: try parseArray()
        case 0x22: _ = try parseString()
        case 0x74: try consumeLiteral("true")
        case 0x66: try consumeLiteral("false")
        case 0x6E: try consumeLiteral("null")
        default: try parseNumber()
        }
    }

    private mutating func parseObject() throws {
        index += 1
        skipWhitespace()
        if consume(0x7D) { return }
        var keys: Set<String> = []
        while true {
            skipWhitespace()
            let key = try parseString()
            guard keys.insert(key).inserted else {
                throw Brain3DIntegrationError.invalidPackage("JSON object contains duplicate key \(key)")
            }
            skipWhitespace()
            guard consume(0x3A) else { throw malformed() }
            try parseValue()
            skipWhitespace()
            if consume(0x7D) { return }
            guard consume(0x2C) else { throw malformed() }
        }
    }

    private mutating func parseArray() throws {
        index += 1
        skipWhitespace()
        if consume(0x5D) { return }
        while true {
            try parseValue()
            skipWhitespace()
            if consume(0x5D) { return }
            guard consume(0x2C) else { throw malformed() }
        }
    }

    private mutating func parseString() throws -> String {
        guard index < bytes.count, bytes[index] == 0x22 else { throw malformed() }
        let start = index
        index += 1
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if escaped {
                escaped = false
                continue
            }
            if byte == 0x5C {
                escaped = true
            } else if byte == 0x22 {
                let data = Data(bytes[start..<index])
                do { return try JSONDecoder().decode(String.self, from: data) }
                catch { throw malformed() }
            } else if byte < 0x20 {
                throw malformed()
            }
        }
        throw malformed()
    }

    private mutating func parseNumber() throws {
        let start = index
        while index < bytes.count,
              [0x2D, 0x2B, 0x2E, 0x45, 0x65].contains(bytes[index])
                || (0x30...0x39).contains(bytes[index]) {
            index += 1
        }
        guard index > start,
              let token = String(bytes: bytes[start..<index], encoding: .utf8),
              let value = Double(token),
              value.isFinite else { throw malformed() }
    }

    private mutating func consumeLiteral(_ literal: String) throws {
        let expected = Array(literal.utf8)
        guard index + expected.count <= bytes.count,
              Array(bytes[index..<(index + expected.count)]) == expected else { throw malformed() }
        index += expected.count
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
            index += 1
        }
    }

    private func malformed() -> Brain3DIntegrationError {
        .invalidPackage("Malformed JSON near byte \(index)")
    }
}
