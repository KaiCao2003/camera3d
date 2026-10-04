import AppKit
import CryptoKit
import Darwin
import Foundation

enum RegistrationWorkerCommand: String, CaseIterable {
    case prepare
    case estimatePose = "estimate-pose"
    case registerSlice = "register-slice"
    case correctSlice = "correct-slice"
    case exportABBA = "export"
    case reviewABBA = "prepare-review"
    case runABBA = "run"
    case registerProject = "register-project"
    case exportAtlas = "export-atlas"
    case reviewBrain3D = "review-brain3d"
    case reviewBlindTracks = "review-blind-tracks"
    case doctor
}

enum WorkerStage: String, Codable, Hashable, Sendable {
    case ok
    case blocked
    case failed
}

struct RegistrationWorkerResult: Codable, Hashable, Sendable {
    var command: String
    var stage: WorkerStage
    var projectID: String?
    var outputPath: String?
    var messages: [String]
    var project: RegistrationProject?
    var slice: SliceRegistrationRecord?
    var export: AtlasExport?
    var brain3DReviewPreview: Brain3DReviewPreview? = nil
    var blindTrackReviewPreview: BlindTrackReviewPreview? = nil
}

enum RegistrationWorkerProgressStage: String, Codable, Hashable, Sendable {
    case preparing
    case loadingAtlas
    case estimatingPose
    case registeringSlices
    case finalizing
    case completed
    case failed

    var title: String {
        switch self {
        case .preparing:
            "Preparing sections"
        case .loadingAtlas:
            "Loading Allen atlas"
        case .estimatingPose:
            "Estimating atlas pose"
        case .registeringSlices:
            "Registering sections"
        case .finalizing:
            "Saving registration results"
        case .completed:
            "Stage complete"
        case .failed:
            "Registration stopped"
        }
    }
}

struct RegistrationWorkerProgress: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var command: String
    var stage: RegistrationWorkerProgressStage
    var completed: Int
    var total: Int
    var failed: Int
    var sliceID: String?
    var sliceTitle: String?
    var message: String
    var updatedAt: String

    init(
        schemaVersion: Int = 1,
        command: String,
        stage: RegistrationWorkerProgressStage,
        completed: Int,
        total: Int,
        failed: Int = 0,
        sliceID: String? = nil,
        sliceTitle: String? = nil,
        message: String,
        updatedAt: String = ISO8601DateFormatter().string(from: Date())
    ) {
        self.schemaVersion = schemaVersion
        self.command = command
        self.stage = stage
        self.completed = completed
        self.total = total
        self.failed = failed
        self.sliceID = sliceID
        self.sliceTitle = sliceTitle
        self.message = message
        self.updatedAt = updatedAt
    }

    var fractionCompleted: Double? {
        guard total > 0 else { return nil }
        return Double(min(max(completed, 0), total)) / Double(total)
    }

    var displayTitle: String {
        if stage == .completed, command == RegistrationWorkerCommand.registerProject.rawValue {
            return "Registration complete"
        }
        return stage.title
    }

    var isValid: Bool {
        schemaVersion == 1
            && completed >= 0
            && total >= 0
            && completed <= total
            && failed >= 0
            && failed <= completed
    }
}

typealias RegistrationWorkerProgressHandler = @Sendable (RegistrationWorkerProgress) -> Void

struct RegistrationWorkerTerminationPolicy: Sendable {
    var gracefulTimeout: TimeInterval = 2
    var forcedTimeout: TimeInterval = 1
    var pollInterval: TimeInterval = 0.02
}

enum RegistrationWorkerError: LocalizedError {
    case missingArgument(String)
    case invalidArgument(String)
    case projectReadFailed(String)
    case sliceNotFound(String)
    case backendUnavailable(String)
    case executionFailed(String)
    case resultReadFailed(String)
    case exportBlocked([String])

    var errorDescription: String? {
        switch self {
        case .missingArgument(let argument):
            "Missing required argument \(argument)"
        case .invalidArgument(let detail):
            "Invalid worker argument: \(detail)"
        case .projectReadFailed(let path):
            "Could not read registration project at \(path)"
        case .sliceNotFound(let id):
            "No registration slice found for \(id)"
        case .backendUnavailable(let detail):
            "Registration backend is unavailable: \(detail)"
        case .executionFailed(let detail):
            "Registration worker failed: \(detail)"
        case .resultReadFailed(let detail):
            "Could not decode registration worker result: \(detail)"
        case .exportBlocked(let blockers):
            "Atlas export blocked: \(blockers.joined(separator: " "))"
        }
    }
}

struct RegistrationWorkerService {
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func makeProject(
        dataset: BrainDataset,
        volume: BrainVolume?,
        channelMappings preferredChannelMappings: [RegistrationChannelMapping]? = nil
    ) -> RegistrationProject {
        let now = Date()
        let channelMappings = preferredChannelMappings ?? makeChannelMappings(dataset: dataset)
        let structuralChannelIDs = Set(
            channelMappings.filter { $0.role == .structural }.map(\.channelIndex)
        )
        let calibrationByGroup = dataset.groups.reduce(into: [String: Double]()) { result, group in
            if let calibration = group.metadata.calibrationMicronsPerPixel {
                result[group.id] = calibration
            }
        }
        let sourceSlices = volume?.slices ?? dataset.allNumberedOverlaySlices.compactMap { slice in
            guard let sourceURL = slice.overlayURL else {
                return nil
            }
            return VolumeSlice(
                id: slice.id,
                title: "\(slice.groupID) \(String(format: "%05d", slice.index))",
                sourceURL: sourceURL,
                groupID: slice.groupID,
                texture: NSImage(),
                width: 0,
                height: 0,
                z: 0,
                offsetX: 0,
                offsetY: 0,
                opacity: 0,
                signal: SliceSignal(
                    redMean: 0,
                    greenMean: 0,
                    blueMean: 0,
                    alphaCoverage: 0,
                    tissueBounds: .zero,
                    imageSize: PixelSize(width: 0, height: 0),
                    componentAreaPixels: 0,
                    componentBounds: .zero,
                    foregroundConfidence: 0,
                    backgroundSuppression: 0
                ),
                registration: .unregistered,
                cortex: .unregistered
            )
        }

        let effectivePixelSizes = sourceSlices.compactMap { slice -> Double? in
            guard let calibration = calibrationByGroup[slice.groupID],
                  let structuralScale = slice.channelImages.first(where: {
                structuralChannelIDs.contains($0.channelIndex)
            })?.sourcePixelScale else { return nil }
            return calibration * max(1, structuralScale)
        }
        let projectPixelSize = median(effectivePixelSizes)
        let records = sourceSlices.map { slice -> SliceRegistrationRecord in
            let structuralScale = slice.channelImages.first(where: {
                structuralChannelIDs.contains($0.channelIndex)
            })?.sourcePixelScale
            let effectivePixelSize = calibrationByGroup[slice.groupID].flatMap { calibration in
                structuralScale.map { calibration * max(1, $0) }
            }
            let pose = SlicePose.estimated(
                apMicrons: slice.registration.atlasAPMicrons,
                confidence: min(0.25, slice.registration.confidence),
                provenance: "Unregistered slice-order prior; the Python worker must replace this estimate"
            )
            var warnings: [String] = []
            if channelMappings.filter({ $0.role == .structural }).isEmpty {
                warnings.append("No structural channel was selected.")
            }
            if effectivePixelSize == nil {
                warnings.append("Missing physical pixel size calibration from Keyence metadata.")
            }
            if structuralScale == nil {
                warnings.append("The selected structural channel is missing from this section.")
            }
            warnings.append(contentsOf: slice.signal.sectionReviewFlags.map { "Section split flag: \($0)." })

            return SliceRegistrationRecord(
                id: slice.id,
                title: slice.title,
                groupID: slice.groupID,
                sourceImagePath: slice.sourceURL.path,
                pixelSizeMicrons: effectivePixelSize,
                imageSize: slice.signal.imageSize,
                status: .unprepared,
                pose: pose,
                transformChain: TransformChain(
                    direction: .atlasToSlice,
                    transforms: [RegistrationTransform.posePrior(pose)]
                ),
                qc: RegistrationQC(
                    landmarkRMSErrorMicrons: nil,
                    majorRegionIoU: nil,
                    mutualInformationMetric: nil,
                    foregroundCoverage: slice.signal.alphaCoverage,
                    warnings: warnings
                ),
                reviewNotes: ""
            )
        }

        return RegistrationProject(
            id: "brainbuilder-\(UUID().uuidString)",
            datasetRootPath: dataset.rootURL.path,
            atlas: .allenCCF2020,
            orientation: .coronal,
            pixelSizeMicrons: projectPixelSize,
            channelMappings: channelMappings,
            slices: records,
            createdAt: now,
            updatedAt: now,
            atlasAssets: AtlasAssetPaths(
                cachePath: AllenAtlasCatalog.brainGlobeCacheURL.path,
                atlasRootPath: nil,
                atlasName: AtlasDescriptor.allenCCF2020.id,
                atlasVersion: AtlasDescriptor.allenCCF2020.version,
                orientation: "asr",
                resolutionMicrons: [25, 25, 25],
                fixturePath: nil
            ),
            sourceMode: volume?.sourceMode ?? .numberedOverlays,
            provenance: RegistrationProjectProvenance(
                datasetFingerprint: datasetFingerprint(for: dataset)
            )
        )
    }

    func prepare(
        project: RegistrationProject,
        volume: BrainVolume?,
        outputURL: URL,
        progressHandler: RegistrationWorkerProgressHandler? = nil
    ) throws -> RegistrationWorkerResult {
        try Task.checkCancellation()
        var materialized = project
        try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
        try Task.checkCancellation()
        if let volume {
            materialized = try materializeSliceRasters(project: materialized, volume: volume, outputURL: outputURL)
        }
        try Task.checkCancellation()
        let projectURL = outputURL.appendingPathComponent("swift-project.json")
        try write(materialized, to: projectURL)
        try Task.checkCancellation()
        return try runWorker(
            command: .prepare,
            arguments: ["--project", projectURL.path, "--out", outputURL.path],
            outputURL: outputURL,
            progressHandler: progressHandler
        )
    }

    func estimatePose(
        project: RegistrationProject,
        outputURL: URL,
        progressHandler: RegistrationWorkerProgressHandler? = nil
    ) throws -> RegistrationWorkerResult {
        let projectURL = try writeRequest(project: project, outputURL: outputURL, name: "pose-request.json")
        return try runWorker(
            command: .estimatePose,
            arguments: ["--project", projectURL.path, "--out", outputURL.path],
            outputURL: outputURL,
            progressHandler: progressHandler
        )
    }

    func registerSlice(
        project: RegistrationProject,
        sliceID: String,
        stage: RegistrationStage,
        outputURL: URL,
        progressHandler: RegistrationWorkerProgressHandler? = nil
    ) throws -> RegistrationWorkerResult {
        guard stage == .affine || stage == .spline else {
            throw RegistrationWorkerError.invalidArgument("register-slice stage must be affine or spline")
        }
        guard project.slices.contains(where: { $0.id == sliceID }) else {
            throw RegistrationWorkerError.sliceNotFound(sliceID)
        }
        let projectURL = try writeRequest(project: project, outputURL: outputURL, name: "register-request.json")
        return try runWorker(
            command: .registerSlice,
            arguments: [
                "--project", projectURL.path,
                "--slice-id", sliceID,
                "--stage", stage.rawValue,
                "--out", outputURL.path
            ],
            outputURL: outputURL,
            progressHandler: progressHandler
        )
    }

    func correctSlice(
        project: RegistrationProject,
        sliceID: String,
        correction: RegistrationCorrection,
        outputURL: URL,
        progressHandler: RegistrationWorkerProgressHandler? = nil
    ) throws -> RegistrationWorkerResult {
        let projectURL = try writeRequest(project: project, outputURL: outputURL, name: "correction-project.json")
        let correctionURL = outputURL.appendingPathComponent("correction.json")
        try JSONEncoder().encode(correction).write(to: correctionURL, options: .atomic)
        return try runWorker(
            command: .correctSlice,
            arguments: ["--project", projectURL.path, "--slice-id", sliceID,
                        "--correction-json", correctionURL.path, "--out", outputURL.path],
            outputURL: outputURL,
            progressHandler: progressHandler
        )
    }

    func exportABBA(project: RegistrationProject, outputURL: URL) throws -> RegistrationWorkerResult {
        let projectURL = try writeRequest(project: project, outputURL: outputURL, name: "source-project.json")
        return try runWorker(
            command: .exportABBA,
            arguments: ["--project", projectURL.path, "--output", outputURL.appendingPathComponent("ABBA").path],
            outputURL: outputURL,
            scriptName: "abba_bridge.py"
        )
    }

    func reviewABBA(bundleURL: URL, resultURL: URL, outputURL: URL) throws -> RegistrationWorkerResult {
        try runWorker(
            command: .reviewABBA,
            arguments: ["--bundle", bundleURL.path, "--result", resultURL.path,
                        "--out", outputURL.appendingPathComponent("review").path],
            outputURL: outputURL,
            scriptName: "abba_bridge.py"
        )
    }

    func runOfficialABBA(
        project: RegistrationProject,
        outputURL: URL,
        progressHandler: RegistrationWorkerProgressHandler? = nil
    ) throws -> RegistrationWorkerResult {
        let handoffURL = outputURL.appendingPathComponent("handoff", isDirectory: true)
        let exported = try exportABBA(project: project, outputURL: handoffURL)
        guard exported.stage == .ok else { return exported }
        try Task.checkCancellation()
        let bundleURL = handoffURL.appendingPathComponent("ABBA", isDirectory: true)
        let nativeBin = officialABBARuntimeRoot()
            .appendingPathComponent("runtime/elastix-5.2.0/bin", isDirectory: true)
        let registered = try runWorker(
            command: .runABBA,
            arguments: [
                "--bundle", bundleURL.path,
                "--output", outputURL.appendingPathComponent("result", isDirectory: true).path,
                "--stage", "spline",
                "--elastix", nativeBin.appendingPathComponent("elastix").path,
                "--transformix", nativeBin.appendingPathComponent("transformix").path,
                "--process-group"
            ],
            outputURL: outputURL.appendingPathComponent("official-run", isDirectory: true),
            progressHandler: progressHandler,
            scriptName: "abba_bridge.py"
        )
        guard registered.stage == .ok else { return registered }
        guard let resultPath = registered.outputPath else {
            throw RegistrationWorkerError.resultReadFailed("Official ABBA returned no result path")
        }
        try Task.checkCancellation()
        return try reviewABBA(
            bundleURL: bundleURL,
            resultURL: URL(fileURLWithPath: resultPath),
            outputURL: outputURL.appendingPathComponent("preview", isDirectory: true)
        )
    }

    func registerProject(
        project: RegistrationProject,
        stage: RegistrationStage = .affine,
        outputURL: URL,
        progressHandler: RegistrationWorkerProgressHandler? = nil
    ) throws -> RegistrationWorkerResult {
        guard stage == .affine || stage == .spline else {
            throw RegistrationWorkerError.invalidArgument("register-project stage must be affine or spline")
        }
        let projectURL = try writeRequest(project: project, outputURL: outputURL, name: "register-all-request.json")
        return try runWorker(
            command: .registerProject,
            arguments: [
                "--project", projectURL.path,
                "--stage", stage.rawValue,
                "--out", outputURL.path
            ],
            outputURL: outputURL,
            progressHandler: progressHandler
        )
    }

    func exportAtlas(project: RegistrationProject, outputURL: URL) throws -> RegistrationWorkerResult {
        let blockers = project.blockersForAtlasExport
        guard blockers.isEmpty else {
            throw RegistrationWorkerError.exportBlocked(blockers)
        }
        let projectURL = try writeRequest(project: project, outputURL: outputURL, name: "export-request.json")
        let result = try runWorker(
            command: .exportAtlas,
            arguments: ["--project", projectURL.path, "--out", outputURL.path],
            outputURL: outputURL
        )
        if result.stage == .blocked {
            throw RegistrationWorkerError.exportBlocked(result.messages)
        }
        if result.stage == .failed {
            throw RegistrationWorkerError.executionFailed(result.messages.joined(separator: " "))
        }
        return result
    }

    func reviewBrain3D(
        project: RegistrationProject,
        outputURL: URL
    ) throws -> RegistrationWorkerResult {
        guard project.brain3dContext?.blindReviewLocked == true else {
            throw RegistrationWorkerError.exportBlocked([
                "Lock blind registration and track review before revealing Brain3D context."
            ])
        }
        let projectURL = try writeRequest(
            project: project,
            outputURL: outputURL,
            name: "brain3d-review-request.json"
        )
        let result = try runWorker(
            command: .reviewBrain3D,
            arguments: ["--project", projectURL.path, "--out", outputURL.path],
            outputURL: outputURL
        )
        if result.stage == .blocked {
            throw RegistrationWorkerError.exportBlocked(result.messages)
        }
        if result.stage == .failed {
            throw RegistrationWorkerError.executionFailed(result.messages.joined(separator: " "))
        }
        guard result.brain3DReviewPreview != nil else {
            throw RegistrationWorkerError.resultReadFailed(
                "Brain3D review worker returned no post-lock preview"
            )
        }
        return result
    }

    func reviewBlindTracks(
        project: RegistrationProject,
        outputURL: URL
    ) throws -> RegistrationWorkerResult {
        guard project.blindReviewLocked == false else {
            throw RegistrationWorkerError.exportBlocked([
                "Unlock blind review before splitting, merging, or reassigning observed tracks."
            ])
        }
        let projectURL = try writeRequest(
            project: project,
            outputURL: outputURL,
            name: "blind-track-review-request.json"
        )
        let result = try runWorker(
            command: .reviewBlindTracks,
            arguments: ["--project", projectURL.path, "--out", outputURL.path],
            outputURL: outputURL
        )
        if result.stage == .blocked {
            throw RegistrationWorkerError.exportBlocked(result.messages)
        }
        if result.stage == .failed {
            throw RegistrationWorkerError.executionFailed(result.messages.joined(separator: " "))
        }
        guard let preview = result.blindTrackReviewPreview,
              preview.passesRetrospectiveBoundary else {
            throw RegistrationWorkerError.resultReadFailed(
                "Blind track review worker returned no valid retrospective preview."
            )
        }
        return result
    }

    func doctor(outputURL: URL) throws -> RegistrationWorkerResult {
        try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
        return try runWorker(command: .doctor, arguments: [], outputURL: outputURL)
    }

    func readProject(at url: URL) throws -> RegistrationProject {
        guard let data = try? Data(contentsOf: url) else {
            throw RegistrationWorkerError.projectReadFailed(url.path)
        }
        do {
            var project = try decoder.decode(RegistrationProject.self, from: data)
            let schemaVersion = project.schemaVersion ?? 1
            guard (1...2).contains(schemaVersion) else {
                throw RegistrationWorkerError.resultReadFailed(
                    "Unsupported registration project schema \(schemaVersion); expected 1 or 2."
                )
            }
            project.migrateToCurrentSchema()
            try project.validateProbeTrackCandidateCapacity()
            return project
        } catch {
            if let workerError = error as? RegistrationWorkerError {
                throw workerError
            }
            throw RegistrationWorkerError.resultReadFailed(Self.decodingFailureDescription(error))
        }
    }

    func write<T: Encodable>(_ value: T, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    func write(_ value: RegistrationProject, to url: URL) throws {
        try value.validateProbeTrackCandidateCapacity()
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    func decodeProgress(_ data: Data) throws -> RegistrationWorkerProgress {
        let progress: RegistrationWorkerProgress
        do {
            progress = try decoder.decode(RegistrationWorkerProgress.self, from: data)
        } catch {
            throw RegistrationWorkerError.resultReadFailed(error.localizedDescription)
        }
        guard progress.isValid else {
            throw RegistrationWorkerError.resultReadFailed("Invalid registration progress sidecar values.")
        }
        return progress
    }

    private static func decodingFailureDescription(_ error: Error) -> String {
        switch error {
        case DecodingError.dataCorrupted(let context),
             DecodingError.typeMismatch(_, let context),
             DecodingError.valueNotFound(_, let context),
             DecodingError.keyNotFound(_, let context):
            return context.debugDescription
        default:
            return error.localizedDescription
        }
    }

    func materializeSliceRasters(
        project: RegistrationProject,
        volume: BrainVolume,
        outputURL: URL
    ) throws -> RegistrationProject {
        try Task.checkCancellation()
        var project = project
        let structuralIDs = Set(project.channelMappings.filter { $0.role == .structural }.map(\.channelIndex))
        let probeIDs = Set(project.channelMappings.filter { $0.role == .probeTrack }.map(\.channelIndex))
        let slicesByID = Dictionary(uniqueKeysWithValues: volume.slices.map { ($0.id, $0) })

        for index in project.slices.indices {
            try Task.checkCancellation()
            let recordID = project.slices[index].id
            guard let volumeSlice = slicesByID[recordID] else {
                throw RegistrationWorkerError.invalidArgument("No rendered tissue section exists for \(recordID)")
            }
            let sliceFolder = outputURL
                .appendingPathComponent("slices", isDirectory: true)
                .appendingPathComponent(safeFilename(recordID), isDirectory: true)
            try Task.checkCancellation()
            try fileManager.createDirectory(at: sliceFolder, withIntermediateDirectories: true)

            guard let structuralChannel = volumeSlice.channelImages.first(where: {
                structuralIDs.contains($0.channelIndex)
            }) else {
                throw RegistrationWorkerError.invalidArgument(
                    "The selected structural channel is missing from \(recordID); composite overlays are not valid structural evidence."
                )
            }
            let probeChannel = volumeSlice.channelImages.first { probeIDs.contains($0.channelIndex) }
            let sourceMask = try Self.sourceRaster(
                volumeSlice.texture,
                undoingCanonicalRotationDegrees: volumeSlice.rotationDegrees
            )
            let sourceStructural = try Self.sourceRaster(
                structuralChannel.texture,
                undoingCanonicalRotationDegrees: volumeSlice.rotationDegrees
            )
            let size = try pixelSize(of: sourceStructural)
            guard let selectionMask = structuralChannel.registrationSelectionMask,
                  try pixelSize(of: selectionMask) == size else {
                throw RegistrationWorkerError.invalidArgument(
                    "A montage-assigned selection domain is required for \(recordID)"
                )
            }
            let structuralURL = sliceFolder.appendingPathComponent("structural.png")
            let selectionURL = sliceFolder.appendingPathComponent("selection-mask.png")
            try Task.checkCancellation()
            try writePNG(sourceStructural, to: structuralURL)
            try writePNG(selectionMask, to: selectionURL)
            if let seeds = structuralChannel.registrationSeedMask {
                try writePNG(seeds, to: sliceFolder.appendingPathComponent("selection-seeds.png"))
            }
            try Task.checkCancellation()
            try writePNG(sourceMask, to: sliceFolder.appendingPathComponent("source-overlay.png"))

            var probeURL: URL?
            if let probeChannel {
                try Task.checkCancellation()
                let structuralSize = size
                let sourceProbe = try Self.sourceRaster(
                    probeChannel.texture,
                    undoingCanonicalRotationDegrees: volumeSlice.rotationDegrees
                )
                let probeSize = try pixelSize(of: sourceProbe)
                guard structuralSize == probeSize else {
                    throw RegistrationWorkerError.invalidArgument(
                        "Probe/structural crops are not pixel-aligned for \(recordID): "
                        + "probe=\(probeSize), structural=\(structuralSize)"
                    )
                }
                let url = sliceFolder.appendingPathComponent("probe-channel.png")
                try Task.checkCancellation()
                try writePNG(sourceProbe, to: url)
                probeURL = url
            }

            try Task.checkCancellation()
            project.slices[index].sourceImagePath = structuralURL.path
            project.slices[index].imageSize = size
            project.slices[index].artifacts = RegistrationArtifacts(
                preparedImagePath: structuralURL.path,
                structuralImagePath: structuralURL.path,
                probeChannelImagePath: probeURL?.path,
                tissueMaskPath: nil,
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
                selectionMaskPath: selectionURL.path
            )
        }
        try Task.checkCancellation()
        let pixelSizes = project.slices.compactMap(\.pixelSizeMicrons)
        project.pixelSizeMicrons = median(pixelSizes) ?? project.pixelSizeMicrons
        project.updatedAt = Date()
        return project
    }

    static func sourceRaster(
        _ canonicalImage: NSImage,
        undoingCanonicalRotationDegrees rotationDegrees: Double
    ) throws -> NSImage {
        let raw = rotationDegrees.truncatingRemainder(dividingBy: 360)
        let normalized = raw < 0 ? raw + 360 : raw
        if abs(normalized) < 0.001 || abs(normalized - 360) < 0.001 {
            return canonicalImage
        }
        guard abs(normalized - 180) < 0.001 else {
            throw RegistrationWorkerError.invalidArgument(
                "Registration materialization supports canonical rotations of 0 or 180 degrees; found \(rotationDegrees)."
            )
        }
        guard let sourceImage = ImageProcessingService.rotated180(canonicalImage) else {
            throw RegistrationWorkerError.invalidArgument(
                "Could not restore the source raster before registration materialization."
            )
        }
        return sourceImage
    }

    private func makeChannelMappings(dataset: BrainDataset) -> [RegistrationChannelMapping] {
        let channels = dataset.groups.flatMap(\.metadata.capturedChannels)
        let unique = Dictionary(grouping: channels, by: \.index)
            .compactMap { _, channels in channels.first }
            .sorted { $0.index < $1.index }

        var mappings = unique.map { channel in
            RegistrationChannelMapping(
                channelIndex: channel.index,
                name: channel.name,
                role: inferredRole(for: channel),
                pseudoColor: channel.pseudoColor
            )
        }
        if !mappings.contains(where: { $0.role == .structural }),
           let fallbackIndex = mappings.lastIndex(where: { $0.role != .probeTrack }) ?? mappings.indices.last {
            mappings[fallbackIndex].role = .structural
        }
        return mappings
    }

    private func inferredRole(for channel: ChannelMetadata) -> RegistrationChannelRole {
        let haystack = "\(channel.name) \(channel.pseudoColor ?? "")".lowercased()
        if ["dapi", "nissl", "autofluores", "brightfield"].contains(where: haystack.contains) {
            return .structural
        }
        if ["gfp", "dii", "dio", "cm-dii", "probe", "electrode"].contains(where: haystack.contains) {
            return .probeTrack
        }
        return .signal
    }

    private func writeRequest(project: RegistrationProject, outputURL: URL, name: String) throws -> URL {
        try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
        let url = outputURL.appendingPathComponent(name)
        try write(project, to: url)
        return url
    }

    private func runWorker(
        command: RegistrationWorkerCommand,
        arguments: [String],
        outputURL: URL,
        progressHandler: RegistrationWorkerProgressHandler? = nil,
        scriptName: String = "brainbuilder_worker.py"
    ) throws -> RegistrationWorkerResult {
        let runtime = try command == .runABBA ? officialABBARuntime() : workerRuntime()
        try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
        let token = UUID().uuidString
        let resultURL = outputURL.appendingPathComponent(".worker-result-\(token).json")
        let progressURL = outputURL.appendingPathComponent(".worker-progress-\(token).json")
        let logURL = outputURL.appendingPathComponent("worker.log")
        defer {
            Self.removeWorkerSidecars([resultURL, progressURL], fileManager: fileManager)
        }
        // A worker run owns this log. Replacing the file prevents stale output from a
        // previous run being mistaken for the current failure diagnostics.
        try Data().write(to: logURL, options: .atomic)
        let logHandle = try FileHandle(forWritingTo: logURL)
        defer { try? logHandle.close() }

        let process = Process()
        process.executableURL = runtime.executable
        var processArguments = runtime.prefixArguments
            + [runtime.rootURL.appendingPathComponent(scriptName).path, command.rawValue]
            + arguments
            + ["--result-json", resultURL.path]
        if progressHandler != nil {
            processArguments += ["--progress-json", progressURL.path]
        }
        process.arguments = processArguments
        var environment = ProcessInfo.processInfo.environment
        environment["BRAINBUILDER_ATLAS_HOME"] = AllenAtlasCatalog.brainGlobeCacheURL.path
        environment["PYTHONUNBUFFERED"] = "1"
        for (key, value) in runtime.environment {
            environment[key] = value
        }
        process.environment = environment
        process.currentDirectoryURL = runtime.rootURL
        process.standardOutput = logHandle
        process.standardError = logHandle

        var lastProgressData: Data?
        func reportProgressIfChanged() {
            guard let progressHandler,
                  let data = try? Data(contentsOf: progressURL),
                  data != lastProgressData,
                  let progress = try? decodeProgress(data) else {
                return
            }
            lastProgressData = data
            progressHandler(progress)
        }

        do {
            try Task.checkCancellation()
            try process.run()
            while process.isRunning {
                reportProgressIfChanged()
                try Task.checkCancellation()
                Thread.sleep(forTimeInterval: 0.05)
            }
            process.waitUntilExit()
            reportProgressIfChanged()
            try logHandle.synchronize()
        } catch is CancellationError {
            if process.isRunning {
                let pid = process.processIdentifier
                guard Self.terminateProcess(process, includingProcessGroup: command == .runABBA) else {
                    throw RegistrationWorkerError.executionFailed(
                        "Could not stop registration worker process \(pid) after cancellation."
                    )
                }
            }
            throw CancellationError()
        } catch {
            throw RegistrationWorkerError.executionFailed(error.localizedDescription)
        }

        try Task.checkCancellation()
        guard let resultData = try? Data(contentsOf: resultURL) else {
            let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "No worker log was produced."
            throw RegistrationWorkerError.resultReadFailed(log)
        }
        let result: RegistrationWorkerResult
        do {
            result = try decoder.decode(RegistrationWorkerResult.self, from: resultData)
        } catch {
            let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            throw RegistrationWorkerError.resultReadFailed("\(error.localizedDescription) \(log)")
        }
        if process.terminationStatus == 0, result.stage != .ok {
            throw RegistrationWorkerError.executionFailed("Worker exited 0 with stage \(result.stage.rawValue).")
        }
        if process.terminationStatus != 0, result.stage == .ok {
            throw RegistrationWorkerError.executionFailed("Worker exited \(process.terminationStatus) after reporting success.")
        }
        return result
    }

    @discardableResult
    static func terminateProcess(
        _ process: Process,
        includingProcessGroup: Bool = false,
        policy: RegistrationWorkerTerminationPolicy = RegistrationWorkerTerminationPolicy()
    ) -> Bool {
        guard process.isRunning else {
            process.waitUntilExit()
            return true
        }

        let pid = process.processIdentifier
        // The bridge owns its group before starting Java/elastix. Never signal
        // an inherited group, which could include BrainBuilder or its launcher.
        if includingProcessGroup, pid > 1, Darwin.getpgid(pid) == pid {
            guard Darwin.kill(-pid, SIGTERM) == 0 || errno == ESRCH else { return false }
            if waitForProcessGroupExit(pid, timeout: policy.gracefulTimeout, pollInterval: policy.pollInterval) {
                process.waitUntilExit()
                return true
            }
            // The group can outlive the Python leader if a native child ignores TERM.
            guard Darwin.kill(-pid, SIGKILL) == 0 || errno == ESRCH else { return false }
            let stopped = waitForProcessGroupExit(pid, timeout: policy.forcedTimeout, pollInterval: policy.pollInterval)
            if stopped { process.waitUntilExit() }
            return stopped
        }

        process.terminate()
        if waitForProcessExit(process, timeout: policy.gracefulTimeout, pollInterval: policy.pollInterval) {
            process.waitUntilExit()
            return true
        }

        if Darwin.kill(pid, SIGKILL) != 0, errno != ESRCH {
            return false
        }
        if waitForProcessExit(process, timeout: policy.forcedTimeout, pollInterval: policy.pollInterval) {
            process.waitUntilExit()
            return true
        }
        return false
    }

    static func removeWorkerSidecars(_ urls: [URL], fileManager: FileManager = .default) {
        for url in urls {
            try? fileManager.removeItem(at: url)
        }
    }

    private static func waitForProcessExit(
        _ process: Process,
        timeout: TimeInterval,
        pollInterval: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: max(0.001, pollInterval))
        }
        return !process.isRunning
    }

    private static func waitForProcessGroupExit(
        _ groupID: pid_t,
        timeout: TimeInterval,
        pollInterval: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        repeat {
            if Darwin.kill(-groupID, 0) != 0, errno == ESRCH { return true }
            Thread.sleep(forTimeInterval: max(0.001, pollInterval))
        } while Date() < deadline
        return Darwin.kill(-groupID, 0) != 0 && errno == ESRCH
    }

    private func officialABBARuntimeRoot() -> URL {
        if let configured = ProcessInfo.processInfo.environment["BRAINBUILDER_ABBA_RUNTIME"] {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/brainbuilder-abba", isDirectory: true)
    }

    private func officialABBARuntime() throws -> WorkerRuntime {
        let runtimeRoot = officialABBARuntimeRoot()
        let python = runtimeRoot.appendingPathComponent("venv/bin/python")
        let roots = workerRootCandidates()
        guard let root = roots.first(where: {
            fileManager.fileExists(atPath: $0.appendingPathComponent("abba_bridge.py").path)
        }), fileManager.isExecutableFile(atPath: python.path) else {
            throw RegistrationWorkerError.backendUnavailable(
                "Official ABBA needs abba_bridge.py and the isolated Python runtime at \(python.path)"
            )
        }
        let nativeBin = runtimeRoot.appendingPathComponent("runtime/elastix-5.2.0/bin", isDirectory: true)
        for name in ["elastix", "transformix"] {
            guard fileManager.isExecutableFile(atPath: nativeBin.appendingPathComponent(name).path) else {
                throw RegistrationWorkerError.backendUnavailable("Official ABBA native executable is missing: \(nativeBin.appendingPathComponent(name).path)")
            }
        }
        var environment = [
            "PATH": runtimeRoot.appendingPathComponent("runtime/apache-maven-3.9.11/bin").path
                + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
        ]
        if let javaHome = ProcessInfo.processInfo.environment["JAVA_HOME"] {
            environment["JAVA_HOME"] = javaHome
        } else {
            let javaHome = Process()
            let output = Pipe()
            javaHome.executableURL = URL(fileURLWithPath: "/usr/libexec/java_home")
            javaHome.arguments = ["-v", "11"]
            javaHome.standardOutput = output
            javaHome.standardError = FileHandle.nullDevice
            try javaHome.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            javaHome.waitUntilExit()
            guard javaHome.terminationStatus == 0,
                  let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty else {
                throw RegistrationWorkerError.backendUnavailable("Official ABBA requires Java 11")
            }
            environment["JAVA_HOME"] = path
        }
        return WorkerRuntime(
            rootURL: root,
            executable: python,
            prefixArguments: [],
            scriptURL: root.appendingPathComponent("abba_bridge.py"),
            environment: environment
        )
    }

    private func workerRuntime() throws -> WorkerRuntime {
        let roots = workerRootCandidates()
        guard let root = roots.first(where: {
            fileManager.fileExists(atPath: $0.appendingPathComponent("brainbuilder_worker.py").path)
                && fileManager.fileExists(atPath: $0.appendingPathComponent("pyproject.toml").path)
        }) else {
            throw RegistrationWorkerError.backendUnavailable(
                "registration-worker/brainbuilder_worker.py was not found. Checked: \(roots.map(\.path).joined(separator: ", "))"
            )
        }
        let script = root.appendingPathComponent("brainbuilder_worker.py")
        let virtualenvPython = root.appendingPathComponent(".venv/bin/python")
        if fileManager.isExecutableFile(atPath: virtualenvPython.path) {
            return WorkerRuntime(
                rootURL: root,
                executable: virtualenvPython,
                prefixArguments: [],
                scriptURL: script,
                environment: [:]
            )
        }

        let bundledUV = Bundle.main.resourceURL?
            .appendingPathComponent("tools", isDirectory: true)
            .appendingPathComponent("uv")
        let uvCandidates = [bundledUV?.path, "/opt/homebrew/bin/uv", "/usr/local/bin/uv"].compactMap { $0 }
        for uvPath in uvCandidates where fileManager.isExecutableFile(atPath: uvPath) {
            let environmentRoot = AllenAtlasCatalog.applicationSupportURL
                .appendingPathComponent("WorkerRuntime", isDirectory: true)
            return WorkerRuntime(
                rootURL: root,
                executable: URL(fileURLWithPath: uvPath),
                prefixArguments: [
                    "run",
                    "--frozen",
                    "--project", root.path,
                    "--python", "3.11",
                    "--no-dev",
                    "python"
                ],
                scriptURL: script,
                environment: [
                    "UV_PROJECT_ENVIRONMENT": environmentRoot.appendingPathComponent("venv", isDirectory: true).path,
                    "UV_PYTHON_INSTALL_DIR": environmentRoot.appendingPathComponent("python", isDirectory: true).path,
                    "UV_CACHE_DIR": environmentRoot.appendingPathComponent("cache", isDirectory: true).path,
                    "UV_NO_PROGRESS": "1"
                ]
            )
        }
        throw RegistrationWorkerError.backendUnavailable(
            "Run `uv sync --project \(root.path) --python 3.11` once, or install uv at /opt/homebrew/bin/uv."
        )
    }

    private func workerRootCandidates() -> [URL] {
        var candidates: [URL] = []
        if let configured = ProcessInfo.processInfo.environment["BRAINBUILDER_WORKER_ROOT"] {
            candidates.append(URL(fileURLWithPath: configured, isDirectory: true))
        }
        // A packaged application must execute the worker it was built and signed
        // with, independent of the directory from which it was launched.
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("registration-worker", isDirectory: true))
        }
        let current = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        candidates.append(current.appendingPathComponent("registration-worker", isDirectory: true))
        let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent()
        candidates.append(bundleParent.deletingLastPathComponent().appendingPathComponent("registration-worker", isDirectory: true))
        return candidates.reduce(into: []) { result, url in
            if !result.contains(url) { result.append(url) }
        }
    }

    private func writePNG(_ image: NSImage, to url: URL) throws {
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            throw RegistrationWorkerError.executionFailed("Could not encode \(url.lastPathComponent) as PNG.")
        }
        try data.write(to: url, options: .atomic)
    }

    private func pixelSize(of image: NSImage) throws -> PixelSize {
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw RegistrationWorkerError.executionFailed("Could not read prepared image pixels.")
        }
        return PixelSize(width: cgImage.width, height: cgImage.height)
    }

    private func safeFilename(_ value: String) -> String {
        value.replacingOccurrences(of: "[^A-Za-z0-9_.-]", with: "-", options: .regularExpression)
    }

    private func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    /// Stable identity for the currently discovered source dataset.  The app
    /// re-evaluates this before blind lock and retrospective export so an
    /// audited subject rebind cannot survive changed source files.
    func datasetFingerprint(for dataset: BrainDataset) -> String {
        var urls: [URL] = []
        for group in dataset.groups {
            urls.append(group.folderURL)
            urls.append(contentsOf: [
                group.metadata.archiveURL,
                group.montageOverlayURL,
                group.montageChannel2URL,
                group.montageChannel3URL
            ].compactMap { $0 })
            for slice in group.slices {
                urls.append(contentsOf: [slice.overlayURL, slice.channel2URL, slice.channel3URL].compactMap { $0 })
            }
        }
        let uniqueURLs = Dictionary(grouping: urls, by: { $0.standardizedFileURL.path })
            .compactMap { $0.value.first }
            .sorted { $0.path < $1.path }
        let manifest = uniqueURLs.map { url -> String in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let relative = url.path.replacingOccurrences(of: dataset.rootURL.path, with: "<dataset>")
            return "\(relative)\t\(values?.fileSize ?? -1)\t\(values?.contentModificationDate?.timeIntervalSince1970 ?? -1)"
        }
        .joined(separator: "\n")
        return SHA256.hash(data: Data(manifest.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private struct WorkerRuntime {
    var rootURL: URL
    var executable: URL
    var prefixArguments: [String]
    var scriptURL: URL
    var environment: [String: String]
}
