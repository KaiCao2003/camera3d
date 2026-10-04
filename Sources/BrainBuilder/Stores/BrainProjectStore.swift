import AppKit
import Combine
import Foundation
import SwiftUI

struct ReviewedStackState: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    var datasetRootPath: String
    var sourceMode: StackSourceMode
    var datasetFingerprint: String
    var excludedSliceIDs: [String]
    var exclusionHistory: [String]
    var archivedRegistrationSlices: [SliceRegistrationRecord]

    func sanitized(validSliceIDs: [String]) -> ReviewedStackState? {
        guard schemaVersion == Self.currentSchemaVersion else {
            return nil
        }

        let validIDs = Set(validSliceIDs)
        let exclusions = Set(excludedSliceIDs.filter(validIDs.contains))
        guard exclusions.count < validIDs.count else {
            return nil
        }

        var seenHistory: Set<String> = []
        var history = exclusionHistory.filter { id in
            exclusions.contains(id) && seenHistory.insert(id).inserted
        }
        for id in validSliceIDs where exclusions.contains(id) && !seenHistory.contains(id) {
            history.append(id)
            seenHistory.insert(id)
        }

        var seenArchives: Set<String> = []
        let archives = archivedRegistrationSlices.filter { record in
            exclusions.contains(record.id) && seenArchives.insert(record.id).inserted
        }

        var result = self
        result.excludedSliceIDs = validSliceIDs.filter(exclusions.contains)
        result.exclusionHistory = history
        result.archivedRegistrationSlices = archives
        return result
    }

    func mergingArchivedSlices(into project: RegistrationProject?) -> RegistrationProject? {
        guard var project else {
            return nil
        }
        var presentIDs = Set(project.slices.map(\.id))
        for record in archivedRegistrationSlices where presentIDs.insert(record.id).inserted {
            project.slices.append(record)
        }
        return project
    }
}

struct RegistrationReviewUndoSnapshot: Equatable {
    var records: [SliceRegistrationRecord]
    var selectedSliceID: String?
    var buttonTitle: String
    var statusMessage: String
    var project: RegistrationProject? = nil
}

enum SectionOrientationState: Equatable, Sendable {
    case notRequired
    case pending
    case estimating
    case ready
    case unavailable(String)

    var permitsSectionRasterPresentation: Bool {
        self == .notRequired || self == .ready
    }

    var detail: String {
        switch self {
        case .notRequired:
            "Raw acquisition-tile preview"
        case .pending:
            "Canonical section orientation has not been estimated"
        case .estimating:
            "Preparing sections and estimating canonical orientation with DeepSlice"
        case .ready:
            "Canonical section orientation verified"
        case .unavailable(let reason):
            reason
        }
    }
}

private struct PendingSectionOrientation {
    var scanGeneration: Int
    var buildGeneration: Int
    var datasetRootPath: String
    var datasetFingerprint: String
    var project: RegistrationProject
    var reviewedVolume: BrainVolume
    var savedProjectURL: URL
}

@MainActor
final class BrainProjectStore: ObservableObject {
    @Published var dataset: BrainDataset?
    @Published var volume: BrainVolume?
    @Published var selectedGroupID: String?
    @Published var selectedSliceID: String?
    @Published var sourceMode: StackSourceMode = .montageSections
    @Published var status: String = "Ready"
    @Published var isScanning = false
    @Published var isBuildingVolume = false
    @Published var isExporting = false
    @Published var isRunningRegistrationWorker = false
    @Published private(set) var isCancelingRegistrationWorker = false
    @Published private(set) var registrationProgress: RegistrationWorkerProgress?
    @Published var lastExportResult: VolumeExportResult?
    @Published var registrationProject: RegistrationProject?
    @Published var selectedRegistrationSliceID: String?
    @Published var selectedProbeTrackCandidateID: String?
    @Published var pendingBrain3DImport: Brain3DPlanImport?
    @Published private(set) var mouseLineResolution: MouseLineSubjectResolution?
    @Published private(set) var isVerifyingMouseLineSubject = false
    @Published var lastWorkerResult: RegistrationWorkerResult?
    @Published var abbaReviewPreview: ABBAReviewPreview?
    @Published var excludedSliceIDs: Set<String> = []
    @Published private(set) var exclusionHistory: [String] = []
    @Published private(set) var registrationReviewUndoSnapshot: RegistrationReviewUndoSnapshot?
    @Published private(set) var sectionOrientationState: SectionOrientationState = .notRequired

    let atlas = AllenAtlasService.shared
    private let registrationWorker = RegistrationWorkerService()
    private let brain3DImportService = Brain3DPlanImportService()
    private let mouseLineSubjectService = MouseLineSubjectService()

    private var unfilteredVolume: BrainVolume?
    private var atlasCancellable: AnyCancellable?
    private var scanGeneration = 0
    private var buildGeneration = 0
    private var exportGeneration = 0
    private var registrationGeneration = 0
    private var scanTask: Task<BrainDataset, Error>?
    private var buildTask: Task<BrainVolume, Error>?
    private var exportTask: Task<VolumeExportResult, Error>?
    private var registrationTask: Task<RegistrationWorkerResult, Error>?
    private var archivedRegistrationSlices: [String: SliceRegistrationRecord] = [:]
    private var pendingSectionOrientation: PendingSectionOrientation?
    private var registrationProjectRestoreFailure: (url: URL, message: String)?

    init() {
        atlasCancellable = atlas.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.objectWillChange.send()
            }
        }
    }

    deinit {
        scanTask?.cancel()
        buildTask?.cancel()
        exportTask?.cancel()
        registrationTask?.cancel()
    }

    func loadDefaultDataIfAvailable() async {
        guard dataset == nil else { return }
        atlas.refreshStatus()

        if let defaultURL = WorkspaceLocator.defaultDataFolder(),
           FileManager.default.fileExists(atPath: defaultURL.path) {
            await scanFolder(defaultURL)
        }
    }

    func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.title = "Choose microscope data folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            Task { await scanFolder(url) }
        }
    }

    func openBrain3DPlanPanel() {
        let panel = NSOpenPanel()
        panel.title = "Load Brain3D Plan"
        panel.prompt = "Verify Plan"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            pendingBrain3DImport = try brain3DImportService.loadPackage(at: url)
            status = "Verified \(pendingBrain3DImport?.handoffs.count ?? 0) immutable Brain3D handoff(s) · select one explicitly"
        } catch {
            pendingBrain3DImport = nil
            status = "Brain3D plan rejected: \(error.localizedDescription)"
        }
    }

    func attachBrain3DHandoff(
        handoffID: String,
        operatorLabel: String = "",
        rebindReason: String = ""
    ) {
        guard requireCurrentDatasetFingerprint(
            before: "attaching a Brain3D handoff"
        ) else { return }
        guard var project = registrationProject,
              let imported = pendingBrain3DImport,
              let handoff = imported.handoffs.first(where: { $0.handoffID == handoffID }),
              let datasetFingerprint = project.provenance?.datasetFingerprint,
              !datasetFingerprint.isEmpty else {
            status = "A registration project, verified handoff, and dataset fingerprint are required"
            return
        }
        let planSubjectID = handoff.subjectID ?? imported.subjectID
        let datasetSubjectID = project.subjectID
        let audit: Brain3DSubjectRebindAudit?
        if datasetSubjectID == planSubjectID {
            audit = nil
        } else if let datasetSubjectID,
                  !operatorLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !rebindReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let handoffHash = handoff.handoffSHA256 {
            audit = Brain3DSubjectRebindAudit(
                auditId: UUID().uuidString.lowercased(),
                planSubjectId: planSubjectID,
                datasetSubjectId: datasetSubjectID,
                datasetFingerprint: datasetFingerprint,
                operatorLabel: operatorLabel,
                reason: rebindReason,
                confirmedAt: Date(),
                handoffSha256: handoffHash
            )
        } else {
            status = "Subject mismatch requires dataset subject ID, operator label, and rebind reason"
            return
        }
        do {
            project.brain3dContext = try brain3DImportService.makeContext(
                from: imported,
                handoff: handoff,
                datasetSubjectID: datasetSubjectID,
                datasetFingerprint: datasetFingerprint,
                rebindAudit: audit
            )
            project.blindReviewLocked = false
            project.updatedAt = Date()
            registrationProject = project
            status = "Attached immutable Brain3D handoff \(handoffID) · overlays remain hidden until blind review lock"
        } catch {
            status = "Could not attach Brain3D handoff: \(error.localizedDescription)"
        }
    }

    func clearBrain3DContext() {
        guard var project = registrationProject else { return }
        project.brain3dContext = nil
        project.blindReviewLocked = false
        project.updatedAt = Date()
        registrationProject = project
        status = "Removed Brain3D context from this registration project"
    }

    func setRegistrationSubjectID(_ value: String) {
        guard var project = registrationProject else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let subjectID = trimmed.isEmpty ? nil : trimmed
        if project.subjectID != subjectID {
            project.colonySubjectReceipt = nil
            mouseLineResolution = nil
        }
        project.subjectID = subjectID
        if project.brain3dContext?.subjectBinding.datasetSubjectId != project.subjectID {
            project.brain3dContext = nil
            project.blindReviewLocked = false
        }
        project.updatedAt = Date()
        registrationProject = project
    }

    func verifyMouseLineSubject(suppliedToken: String? = nil) async {
        guard !isVerifyingMouseLineSubject, !isBusy else { return }
        guard let project = registrationProject,
              let subjectID = project.subjectID,
              !subjectID.isEmpty else {
            status = MouseLineIntegrationError.missingSubjectID.localizedDescription
            return
        }
        isVerifyingMouseLineSubject = true
        defer { isVerifyingMouseLineSubject = false }
        do {
            let resolution = try await mouseLineSubjectService.resolveSubject(
                identifier: subjectID,
                suppliedToken: suppliedToken
            )
            guard registrationProject == project else {
                status = "Ignored stale mouse_line response because the registration project changed"
                return
            }
            var keychainWarning: String?
            if let suppliedToken, !suppliedToken.isEmpty {
                do {
                    try mouseLineSubjectService.rememberSuppliedToken(suppliedToken)
                } catch {
                    keychainWarning = error.localizedDescription
                }
            }
            applyMouseLineResolution(
                resolution,
                requestedProject: project,
                requestedSubjectID: subjectID,
                keychainWarning: keychainWarning
            )
        } catch {
            status = error.localizedDescription
        }
    }

    @discardableResult
    func applyMouseLineResolution(
        _ resolution: MouseLineSubjectResolution,
        requestedProject: RegistrationProject,
        requestedSubjectID: String,
        keychainWarning: String? = nil
    ) -> Bool {
        guard var project = registrationProject,
              project == requestedProject,
              project.subjectID == requestedSubjectID else {
            status = "Ignored stale mouse_line response because the registration project changed"
            return false
        }
        mouseLineResolution = resolution
        guard resolution.isExactPublicIDMatch(for: requestedSubjectID) else {
            project.colonySubjectReceipt = nil
            project.updatedAt = Date()
            registrationProject = project
            persistRegistrationProject()
            status = "mouse_line matched \(requestedSubjectID) as a legacy ID for \(resolution.subject.publicId). Change the project subject ID explicitly, then verify again."
            return true
        }
        project.colonySubjectReceipt = mouseLineSubjectService.makeReceipt(from: resolution)
        project.updatedAt = Date()
        registrationProject = project
        persistRegistrationProject()
        if let keychainWarning {
            status = "Verified mouse_line public ID \(requestedSubjectID), but the token was not saved: \(keychainWarning)"
        } else {
            status = "Verified mouse_line public ID \(requestedSubjectID) through SSH \(mouseLineSubjectService.endpoint.sshHost):\(mouseLineSubjectService.endpoint.sshRemotePort)"
        }
        return true
    }

    func changeSourceMode(to mode: StackSourceMode) {
        guard mode != sourceMode, !isBusy else { return }
        sourceMode = mode
        volume = nil
        pendingSectionOrientation = nil
        sectionOrientationState = mode == .montageSections ? .pending : .notRequired
        Task { @MainActor [weak self] in
            await self?.rebuildVolume()
        }
    }

    func scanFolder(_ url: URL) async {
        scanGeneration += 1
        buildGeneration += 1
        exportGeneration += 1
        registrationGeneration += 1
        let generation = scanGeneration
        scanTask?.cancel()
        buildTask?.cancel()
        exportTask?.cancel()
        registrationTask?.cancel()
        exportTask = nil
        registrationTask = nil
        isExporting = false
        isRunningRegistrationWorker = false
        isCancelingRegistrationWorker = false
        registrationProgress = nil
        pendingSectionOrientation = nil
        sectionOrientationState = sourceMode == .montageSections ? .pending : .notRequired

        isScanning = true
        status = "Scanning \(url.lastPathComponent)..."
        volume = nil
        unfilteredVolume = nil
        excludedSliceIDs = []
        exclusionHistory = []
        archivedRegistrationSlices = [:]
        registrationReviewUndoSnapshot = nil
        registrationProject = nil
        selectedSliceID = nil
        selectedRegistrationSliceID = nil
        lastExportResult = nil
        lastWorkerResult = nil
        defer {
            if generation == scanGeneration {
                isScanning = false
                scanTask = nil
            }
        }

        do {
            let task = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return try DatasetScanner().scan(rootURL: url)
            }
            scanTask = task

            let scanned = try await task.value
            guard generation == scanGeneration else {
                return
            }

            dataset = scanned
            selectedGroupID = scanned.groups.first?.id
            status = "Loaded \(scanned.groups.count) XY groups, \(scanned.totalSlices) numbered slices, \(scanned.montageCount) montage overlays"
            await rebuildVolume()
        } catch is CancellationError {
            if generation == scanGeneration {
                status = "Scan canceled"
                if sourceMode == .montageSections {
                    sectionOrientationState = .unavailable("Dataset scan was canceled before section orientation could be estimated")
                }
            }
        } catch {
            if generation == scanGeneration {
                status = "Scan failed: \(error.localizedDescription)"
                if sourceMode == .montageSections {
                    sectionOrientationState = .unavailable(status)
                }
            }
        }
    }

    func rebuildVolume() async {
        guard !isRunningRegistrationWorker, !isCancelingRegistrationWorker else {
            status = isCancelingRegistrationWorker
                ? "Wait for registration cancellation to finish before rebuilding the 3D stack"
                : "Cancel registration before rebuilding the 3D stack"
            return
        }
        guard let dataset else {
            status = "No dataset loaded"
            return
        }

        buildGeneration += 1
        let generation = buildGeneration
        buildTask?.cancel()

        isBuildingVolume = true
        if sourceMode == .montageSections {
            pendingSectionOrientation = nil
            sectionOrientationState = .pending
            volume = nil
        }
        status = "Building 3D stack..."
        defer {
            if generation == buildGeneration {
                isBuildingVolume = false
                buildTask = nil
            }
        }

        let mode = sourceMode
        do {
            let task = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return try BrainVolumeBuilder().build(dataset: dataset, mode: mode)
            }
            buildTask = task

            let built = try await task.value
            guard generation == buildGeneration else {
                return
            }

            unfilteredVolume = built
            restoreReviewedStackState(for: dataset, baseVolume: built)
            installReviewedVolume(
                from: built,
                dataset: dataset,
                preservingChannelRolesFrom: nil,
                statusMessage: "Built \(built.slices.count) 3D slices from \(built.buildSummary.sourceImages) source image(s)"
            )
        } catch is CancellationError {
            if generation == buildGeneration {
                status = "Build canceled"
                if sourceMode == .montageSections {
                    sectionOrientationState = .unavailable("3D build was canceled before section orientation could be estimated")
                }
            }
        } catch {
            if generation == buildGeneration {
                status = "3D build failed: \(error.localizedDescription)"
                if sourceMode == .montageSections {
                    sectionOrientationState = .unavailable(status)
                }
            }
        }
    }

    func exportCurrentVolumeWithPanel() {
        guard let dataset, let volume else {
            status = "No 3D stack to export"
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export 3D reconstruction"
        panel.nameFieldStringValue = "BrainBuilderReconstruction"
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            export(volume: volume, dataset: dataset, to: url)
        }
    }

    func excludeVolumeSlice(id: String) {
        guard !isBusy else {
            status = "Wait for the current operation to finish before changing the reviewed stack"
            return
        }
        guard let dataset, let baseVolume = unfilteredVolume else {
            status = "No reviewed stack is available"
            return
        }
        guard baseVolume.slices.contains(where: { $0.id == id }) else {
            status = "Section is not part of the current stack"
            return
        }
        guard !excludedSliceIDs.contains(id) else {
            status = "Section is already excluded"
            return
        }
        guard baseVolume.slices.count - excludedSliceIDs.count > 1 else {
            status = "Cannot exclude the last remaining section"
            return
        }

        if let record = registrationProject?.slices.first(where: { $0.id == id }) {
            archivedRegistrationSlices[id] = record
        }
        registrationReviewUndoSnapshot = nil
        excludedSliceIDs.insert(id)
        exclusionHistory.removeAll { $0 == id }
        exclusionHistory.append(id)
        let title = baseVolume.slices.first { $0.id == id }?.title ?? "section"
        installReviewedVolume(
            from: baseVolume,
            dataset: dataset,
            preservingChannelRolesFrom: registrationProject,
            statusMessage: "Excluded \(title) from the reviewed stack"
        )
    }

    func undoLastVolumeSliceExclusion() {
        guard let id = exclusionHistory.last else {
            status = "No section exclusion to undo"
            return
        }
        restoreExcludedVolumeSlice(id: id)
    }

    func restoreExcludedVolumeSlice(id: String) {
        guard !isBusy else {
            status = "Wait for the current operation to finish before restoring sections"
            return
        }
        guard let dataset, let baseVolume = unfilteredVolume else {
            status = "No reviewed stack is available"
            return
        }
        guard excludedSliceIDs.contains(id) else {
            status = "Section is not excluded"
            return
        }

        registrationReviewUndoSnapshot = nil
        let preservationProject = reviewedProjectByMergingArchivedSlices()
        let title = baseVolume.slices.first { $0.id == id }?.title ?? "section"
        excludedSliceIDs.remove(id)
        exclusionHistory.removeAll { $0 == id }
        archivedRegistrationSlices.removeValue(forKey: id)
        installReviewedVolume(
            from: baseVolume,
            dataset: dataset,
            preservingChannelRolesFrom: preservationProject,
            statusMessage: "Restored \(title) to the reviewed stack"
        )
        selectVolumeSlice(id: id)
        if registrationProject?.slices.contains(where: { $0.id == id }) == true {
            selectedRegistrationSliceID = id
        }
    }

    func restoreExcludedVolumeSlices() {
        guard !isBusy else {
            status = "Wait for the current operation to finish before restoring sections"
            return
        }
        guard let dataset, let baseVolume = unfilteredVolume else {
            status = "No reviewed stack is available"
            return
        }
        guard !excludedSliceIDs.isEmpty else {
            status = "No excluded sections to restore"
            return
        }

        registrationReviewUndoSnapshot = nil
        let preservationProject = reviewedProjectByMergingArchivedSlices()
        let lastRestoredID = exclusionHistory.last
        excludedSliceIDs = []
        exclusionHistory = []
        archivedRegistrationSlices = [:]
        installReviewedVolume(
            from: baseVolume,
            dataset: dataset,
            preservingChannelRolesFrom: preservationProject,
            statusMessage: "Restored all detected sections"
        )
        if let lastRestoredID {
            selectVolumeSlice(id: lastRestoredID)
            if registrationProject?.slices.contains(where: { $0.id == lastRestoredID }) == true {
                selectedRegistrationSliceID = lastRestoredID
            }
        }
    }

    func prepareRegistrationProject() {
        guard registrationProject?.blindReviewLocked != true else {
            status = "Unlock blind review before rerunning registration"
            return
        }
        guard let project = registrationProject, let volume else {
            status = "No registration project to prepare"
            return
        }
        guard sourceMode == .montageSections, project.sourceMode == .montageSections else {
            status = "Registration requires detected montage sections; acquisition tiles are preview-only"
            return
        }
        let outputURL = defaultRegistrationWorkerFolder()
        runRegistrationWorker(
            "Preparing registration project...",
            progressOperation: { progress in
                progress(
                    RegistrationWorkerProgress(
                        command: RegistrationWorkerCommand.prepare.rawValue,
                        stage: .preparing,
                        completed: 0,
                        total: project.slices.count,
                        message: "Materializing \(project.slices.count) selected section crop(s)."
                    )
                )
                return try RegistrationWorkerService().prepare(
                    project: project,
                    volume: volume,
                    outputURL: outputURL,
                    progressHandler: progress
                )
            },
            onSuccess: { [weak self] result in
                if let project = result.project {
                    self?.publishVerifiedRegistrationProject(project)
                }
            },
            persistsProjectOnCompletion: false
        )
    }

    func autoRegisterAll() {
        guard registrationProject?.blindReviewLocked != true else {
            status = "Unlock blind review before rerunning registration"
            return
        }
        guard let project = registrationProject, let volume else {
            status = "Build a reviewed montage stack before automatic registration"
            return
        }
        guard sourceMode == .montageSections else {
            status = "Atlas registration requires detected montage sections; numbered files are overlapping acquisition tiles"
            return
        }
        let outputURL = defaultRegistrationWorkerFolder()
        runRegistrationWorker(
            "Preparing sections, matching AP planes, and registering all slices...",
            progressOperation: { progress in
                let worker = RegistrationWorkerService()
                progress(
                    RegistrationWorkerProgress(
                        command: RegistrationWorkerCommand.prepare.rawValue,
                        stage: .preparing,
                        completed: 0,
                        total: project.slices.count,
                        message: "Materializing \(project.slices.count) selected section crop(s)."
                    )
                )
                let prepared = try worker.prepare(
                    project: project,
                    volume: volume,
                    outputURL: outputURL,
                    progressHandler: progress
                )
                guard let preparedProject = prepared.project else {
                    throw RegistrationWorkerError.resultReadFailed("Prepare returned no project")
                }
                let posed = try worker.estimatePose(
                    project: preparedProject,
                    outputURL: outputURL,
                    progressHandler: progress
                )
                guard let posedProject = posed.project else {
                    throw RegistrationWorkerError.resultReadFailed("Pose estimation returned no project")
                }
                return try worker.registerProject(
                    project: posedProject,
                    stage: .affine,
                    outputURL: outputURL,
                    progressHandler: progress
                )
            },
            onSuccess: { [weak self] result in
                if let project = result.project {
                    self?.publishVerifiedRegistrationProject(project)
                }
            },
            persistsProjectOnCompletion: false
        )
    }

    func acceptAllRegisteredSlices() {
        guard !isRunningRegistrationWorker else {
            status = "Wait for registration to finish before accepting slices"
            return
        }
        guard var project = registrationProject else {
            status = "No registration project loaded"
            return
        }
        guard project.sourceMode == .montageSections else {
            status = "Only verified montage sections can be accepted as serial histology"
            return
        }
        let eligibleIndices = project.slices.indices.filter { index in
            let slice = project.slices[index]
            return (slice.status == .affineDone || slice.status == .splineDone)
                && slice.isReadyForAcceptance
        }
        guard !eligibleIndices.isEmpty else {
            status = "No QC-passing sections are ready for bulk acceptance"
            return
        }

        let previousRecords = eligibleIndices.map { project.slices[$0] }
        let selectedWasAccepted = selectedRegistrationSliceID.map { selectedID in
            previousRecords.contains { $0.id == selectedID }
        } ?? true
        recordRegistrationReviewUndo(
            records: previousRecords,
            buttonTitle: "Undo Bulk Accept",
            statusMessage: "Undid acceptance of \(previousRecords.count) QC-passing section(s)"
        )
        for index in eligibleIndices {
            project.slices[index].status = .accepted
        }
        project.updatedAt = Date()
        registrationProject = project
        if selectedWasAccepted,
           let nextID = project.nextPendingReviewSliceID(after: selectedRegistrationSliceID) {
            selectedRegistrationSliceID = nextID
        }
        persistRegistrationProject()
        let pending = project.pendingReviewSlices.count
        let failed = project.slices.filter { $0.status == .failed }.count
        if pending > 0 {
            status = "Accepted \(eligibleIndices.count) QC-passing section(s) · \(pending) still await decisions"
        } else if failed > 0 {
            status = "Review complete · \(failed) rejected section(s) still block export"
        } else {
            status = "Review complete · all sections accepted"
        }
    }

    func estimateRegistrationPose() {
        guard registrationProject?.blindReviewLocked != true else {
            status = "Unlock blind review before rerunning pose estimation"
            return
        }
        guard let project = registrationProject else {
            status = "No registration project for pose estimation"
            return
        }
        guard sourceMode == .montageSections, project.sourceMode == .montageSections else {
            status = "Pose estimation requires detected montage sections"
            return
        }
        guard !project.slices.isEmpty,
              project.slices.allSatisfy(\.hasMaterializedRegistrationInput) else {
            status = "Run Prepare first so every section has a unique materialized crop"
            return
        }
        let outputURL = defaultRegistrationWorkerFolder()
        runRegistrationWorker(
            "Estimating atlas pose...",
            progressOperation: { progress in
                try RegistrationWorkerService().estimatePose(
                    project: project,
                    outputURL: outputURL,
                    progressHandler: progress
                )
            },
            onSuccess: { [weak self] result in
                if let project = result.project {
                    self?.publishVerifiedRegistrationProject(project)
                }
            },
            persistsProjectOnCompletion: false
        )
    }

    func runSelectedSliceRegistration(stage: RegistrationStage) {
        guard registrationProject?.blindReviewLocked != true else {
            status = "Unlock blind review before rerunning registration"
            return
        }
        guard let project = registrationProject else {
            status = "No registration project loaded"
            return
        }
        guard let selectedRegistrationSliceID else {
            status = "No slice selected for registration"
            return
        }
        guard sourceMode == .montageSections, project.sourceMode == .montageSections else {
            status = "Registration requires detected montage sections"
            return
        }
        guard let selected = project.slices.first(where: { $0.id == selectedRegistrationSliceID }),
              selected.hasMaterializedRegistrationInput,
              selected.hasWorkerEstimatedPose else {
            status = "Run Prepare and Pose before affine registration"
            return
        }
        let outputURL = defaultRegistrationWorkerFolder()
        runRegistrationWorker(
            "Running \(stage.title) registration...",
            progressOperation: { progress in
                try RegistrationWorkerService().registerSlice(
                    project: project,
                    sliceID: selectedRegistrationSliceID,
                    stage: stage,
                    outputURL: outputURL,
                    progressHandler: progress
                )
            },
            onSuccess: { [weak self] result in
                guard let slice = result.slice else {
                    return
                }
                self?.replaceRegistrationSlice(slice)
            }
        )
    }

    var canCorrectSelectedRegistrationSlice: Bool {
        sourceMode == .montageSections
            && registrationProject?.blindReviewLocked != true
            && registrationProject?.brain3dContext?.blindReviewLocked != true
            && selectedRegistrationSlice?.hasMaterializedRegistrationInput == true
            && selectedRegistrationSlice?.hasWorkerEstimatedPose == true
            && selectedRegistrationSlice?.artifacts?.atlasReferencePath != nil
    }

    var canUndoRegistrationCorrection: Bool {
        !isBusy && registrationReviewUndoSnapshot?.buttonTitle == "Undo correction"
    }

    func undoRegistrationCorrection() {
        guard canUndoRegistrationCorrection else { return }
        undoLastWorkspaceAction()
    }

    func correctSelectedRegistrationSlice(
        _ correction: RegistrationCorrection,
        onSuccess: @escaping (SliceRegistrationRecord) -> Void
    ) {
        guard !isBusy, canCorrectSelectedRegistrationSlice,
              let project = registrationProject, let selected = selectedRegistrationSlice,
              correction.hasValidPlane,
              correction.landmarks.isEmpty || correction.hasUsableLandmarks else {
            status = "Correction requires a valid plane and at least three non-collinear landmark pairs"
            return
        }
        let outputURL = defaultRegistrationWorkerFolder()
        runRegistrationWorker(
            "Applying section correction…",
            progressOperation: { progress in
                try RegistrationWorkerService().correctSlice(
                    project: project, sliceID: selected.id, correction: correction,
                    outputURL: outputURL, progressHandler: progress
                )
            },
            onSuccess: { [weak self] result in
                guard let self, let slice = result.slice, slice.id == selected.id,
                      let correctedProject = result.project, correctedProject.id == project.id,
                      self.registrationProject?.id == project.id else { return }
                self.recordRegistrationReviewUndo(
                    records: [selected], buttonTitle: "Undo correction",
                    statusMessage: "Restored section and track review before correction",
                    project: project
                )
                // A changed transform invalidates the worker's dependent blind
                // reconstruction and post-lock review, not only the selected row.
                self.registrationProject = correctedProject
                self.replaceRegistrationSlice(slice, preservingReviewUndo: true)
                onSuccess(slice)
            }
        )
    }

    func exportABBABundleWithPanel() {
        guard !isBusy, let project = registrationProject,
              project.sourceMode == .montageSections,
              project.slices.allSatisfy(\.hasWorkerEstimatedPose) else {
            status = "Estimate section poses before exporting to ABBA"
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for the ABBA handoff"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let outputURL = parent.appendingPathComponent("BrainBuilder-ABBA-\(UUID().uuidString.prefix(8))", isDirectory: true)
        runRegistrationWorker(
            "Exporting canonical sections for ABBA…",
            operation: { try RegistrationWorkerService().exportABBA(project: project, outputURL: outputURL) },
            onSuccess: { _ in NSWorkspace.shared.activateFileViewerSelecting([outputURL]) },
            persistsProjectOnCompletion: false
        )
    }

    func openABBAResultWithPanel() {
        guard !isBusy else { return }
        let resultPanel = NSOpenPanel()
        resultPanel.title = "Open an official ABBA result.json"
        resultPanel.canChooseDirectories = false
        resultPanel.allowedContentTypes = [.json]
        guard resultPanel.runModal() == .OK, let resultURL = resultPanel.url else { return }

        let bundleURL: URL
        if let savedBundleURL = Self.existingABBABundleURL(for: resultURL) {
            bundleURL = savedBundleURL
        } else {
            let bundlePanel = NSOpenPanel()
            bundlePanel.title = "Select the original ABBA handoff folder"
            bundlePanel.message = "The source manifest is used to verify that the images and transforms belong to this result."
            bundlePanel.canChooseFiles = false
            bundlePanel.canChooseDirectories = true
            guard bundlePanel.runModal() == .OK, let selectedURL = bundlePanel.url else { return }
            bundleURL = selectedURL
        }
        let outputURL = defaultRegistrationWorkerFolder()
            .appendingPathComponent("abba-review-\(UUID().uuidString)", isDirectory: true)
        runRegistrationWorker(
            "Validating and rendering the official ABBA result…",
            operation: {
                try RegistrationWorkerService().reviewABBA(
                    bundleURL: bundleURL, resultURL: resultURL, outputURL: outputURL
                )
            },
            onSuccess: { [weak self] result in
                guard let self, let path = result.outputPath else { return }
                do {
                    self.abbaReviewPreview = try ABBAReviewPreview.read(from: URL(fileURLWithPath: path))
                } catch {
                    self.status = error.localizedDescription
                }
            },
            persistsProjectOnCompletion: false
        )
    }

    nonisolated static func existingABBABundleURL(for resultURL: URL) -> URL? {
        struct ResultLocation: Decodable {
            var bundlePath: String?
        }
        guard let data = try? Data(contentsOf: resultURL),
              let location = try? JSONDecoder().decode(ResultLocation.self, from: data),
              let path = location.bundlePath,
              NSString(string: path).isAbsolutePath else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        // This is only a location hint; reviewABBA still validates every source and result.
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func runOfficialABBA() {
        guard !isBusy, let project = registrationProject,
              project.sourceMode == .montageSections,
              !project.slices.isEmpty,
              project.slices.allSatisfy(\.hasWorkerEstimatedPose) else {
            status = "Estimate section poses before running official ABBA"
            return
        }
        let outputURL = defaultRegistrationWorkerFolder()
            .appendingPathComponent("official-abba-\(UUID().uuidString)", isDirectory: true)
        runRegistrationWorker(
            "Exporting sections and starting official ABBA affine + spline…",
            progressOperation: { progress in
                try RegistrationWorkerService().runOfficialABBA(
                    project: project, outputURL: outputURL, progressHandler: progress
                )
            },
            onSuccess: { [weak self] result in
                guard let self, let path = result.outputPath else { return }
                do {
                    self.abbaReviewPreview = try ABBAReviewPreview.read(from: URL(fileURLWithPath: path))
                } catch {
                    self.status = error.localizedDescription
                }
            },
            persistsProjectOnCompletion: false
        )
    }

    func acceptSelectedRegistrationSlice() {
        guard !isRunningRegistrationWorker else {
            status = "Wait for registration to finish before accepting a slice"
            return
        }
        guard var slice = selectedRegistrationSlice else {
            status = "No registration slice selected"
            return
        }
        guard slice.status != .accepted else {
            status = "\(slice.title) is already accepted"
            return
        }
        guard registrationProject?.sourceMode == .montageSections,
              slice.isReadyForAcceptance else {
            status = "Slice needs a validated transform and matching atlas artifacts before acceptance"
            return
        }
        recordRegistrationReviewUndo(
            records: [slice],
            buttonTitle: "Undo Accept",
            statusMessage: "Undid acceptance of \(slice.title)"
        )
        slice.status = .accepted
        replaceRegistrationSlice(slice, preservingReviewUndo: true)
        if let nextID = registrationProject?.nextPendingReviewSliceID(after: slice.id) {
            selectedRegistrationSliceID = nextID
            let nextTitle = registrationProject?.slices.first { $0.id == nextID }?.title ?? "next section"
            status = "Accepted \(slice.title) · reviewing \(nextTitle) next"
        } else {
            status = "Accepted \(slice.title) · all sections have a review decision"
        }
    }

    func rejectSelectedRegistrationSlice() {
        guard !isRunningRegistrationWorker else {
            status = "Wait for registration to finish before rejecting a slice"
            return
        }
        guard var slice = selectedRegistrationSlice else {
            status = "No registration slice selected"
            return
        }
        guard slice.status != .failed else {
            status = "\(slice.title) is already rejected"
            return
        }
        recordRegistrationReviewUndo(
            records: [slice],
            buttonTitle: "Undo Reject",
            statusMessage: "Undid rejection of \(slice.title)"
        )
        slice.status = .failed
        replaceRegistrationSlice(slice, preservingReviewUndo: true)
        if let nextID = registrationProject?.nextPendingReviewSliceID(after: slice.id) {
            selectedRegistrationSliceID = nextID
            let nextTitle = registrationProject?.slices.first { $0.id == nextID }?.title ?? "next section"
            status = "Rejected \(slice.title) · reviewing \(nextTitle) next"
        } else {
            status = "Rejected \(slice.title) · all sections have a review decision"
        }
    }

    func acceptSelectedProbeTrack() {
        guard !isRunningRegistrationWorker else {
            status = "Wait for registration to finish before reviewing the probe track"
            return
        }
        guard registrationProject?.blindReviewLocked != true else {
            status = "Unlock blind review before changing a track decision"
            return
        }
        guard var slice = selectedRegistrationSlice else {
            status = "No atlas-mapped probe-track candidate is available"
            return
        }
        var candidates = slice.effectiveProbeTrackCandidates
        let candidateIndex = selectedProbeTrackCandidateID.flatMap { selectedID in
            candidates.firstIndex { $0.candidateId == selectedID }
        } ?? candidates.indices.first
        guard let candidateIndex,
              !candidates[candidateIndex].atlasPoints.isEmpty else {
            status = "No atlas-mapped probe-track candidate is available"
            return
        }
        candidates[candidateIndex].reviewAccepted = true
        candidates[candidateIndex].status = "atlasMapped"
        recordRegistrationReviewUndo(
            records: [slice],
            buttonTitle: "Undo Track Review",
            statusMessage: "Undid probe-track acceptance for \(slice.title)"
        )
        slice.probeTrackCandidates = candidates
        if candidateIndex == candidates.startIndex {
            slice.probeTrack = candidates[candidateIndex]
        }
        replaceRegistrationSlice(slice, preservingReviewUndo: true)
        clearBlindTrackMembershipAfterSliceEdit()
        selectedProbeTrackCandidateID = candidates[candidateIndex].candidateId
        status = "Accepted probe-track candidate \(candidateIndex + 1) for \(slice.title)"
    }

    func rejectSelectedProbeTrack() {
        guard !isRunningRegistrationWorker else {
            status = "Wait for registration to finish before reviewing the probe track"
            return
        }
        guard registrationProject?.blindReviewLocked != true else {
            status = "Unlock blind review before changing a track decision"
            return
        }
        guard var slice = selectedRegistrationSlice else {
            status = "No probe-track candidate is available"
            return
        }
        var candidates = slice.effectiveProbeTrackCandidates
        let candidateIndex = selectedProbeTrackCandidateID.flatMap { selectedID in
            candidates.firstIndex { $0.candidateId == selectedID }
        } ?? candidates.indices.first
        guard let candidateIndex else {
            status = "No probe-track candidate is available"
            return
        }
        candidates[candidateIndex].reviewAccepted = false
        candidates[candidateIndex].status = "rejected"
        recordRegistrationReviewUndo(
            records: [slice],
            buttonTitle: "Undo Track Review",
            statusMessage: "Undid probe-track rejection for \(slice.title)"
        )
        slice.probeTrackCandidates = candidates
        if candidateIndex == candidates.startIndex {
            slice.probeTrack = candidates[candidateIndex]
        }
        replaceRegistrationSlice(slice, preservingReviewUndo: true)
        clearBlindTrackMembershipAfterSliceEdit()
        selectedProbeTrackCandidateID = candidates[candidateIndex].candidateId
        status = "Rejected probe-track candidate \(candidateIndex + 1) for \(slice.title)"
    }

    func selectProbeTrackCandidate(_ candidateID: String?) {
        selectedProbeTrackCandidateID = candidateID
    }

    func buildBlindTrackReview() {
        guard requireCurrentDatasetFingerprint(
            before: "building blind observed-track review"
        ) else { return }
        guard !isBusy else {
            status = "Wait for the current operation before reconstructing blind tracks"
            return
        }
        guard let project = registrationProject, project.blindReviewLocked == false else {
            status = "Unlock blind review before reconstructing or editing observed tracks"
            return
        }
        let unresolved = project.acceptedSlices.flatMap { slice in
            slice.effectiveProbeTrackCandidates.filter {
                $0.reviewAccepted != true && $0.status != "rejected"
            }
        }
        guard unresolved.isEmpty else {
            status = "Review every 2D blind candidate before reconstructing 3D tracks"
            return
        }
        let outputURL = defaultRegistrationWorkerFolder()
        runRegistrationWorker(
            "Reconstructing blind 3D tracks without plan context...",
            operation: {
                try RegistrationWorkerService().reviewBlindTracks(
                    project: project,
                    outputURL: outputURL
                )
            },
            onSuccess: { [weak self] result in
                guard let self,
                      let preview = result.blindTrackReviewPreview else { return }
                self.applyBlindTrackReviewPreview(preview, requestedProject: project)
            }
        )
    }

    @discardableResult
    func applyBlindTrackReviewPreview(
        _ preview: BlindTrackReviewPreview,
        requestedProject: RegistrationProject
    ) -> Bool {
        guard preview.passesRetrospectiveBoundary,
              var updated = registrationProject,
              updated == requestedProject,
              updated.blindReviewLocked == false else {
            status = "Ignored stale blind-track review because the registration project changed"
            return false
        }
        updated.blindTrackReviewPreview = preview
        updated.blindTrackReview = preview.asEditableState
        updated.updatedAt = Date()
        registrationProject = updated
        persistRegistrationProject()
        status = "Reviewed \(preview.tracks.count) blind 3D track(s) · plan and ROI context remained hidden"
        return true
    }

    func splitBlindTrack(_ trackID: String, sourcePointIDs: Set<String>) {
        guard let preview = registrationProject?.blindTrackReviewPreview else {
            status = "Build the blind 3D track review before splitting a track"
            return
        }
        do {
            let state = try BlindTrackReviewEditor.split(
                preview: preview,
                trackID: trackID,
                selectedSourcePointIDs: sourcePointIDs
            )
            applyBlindTrackReviewState(state, action: "Split blind track")
        } catch {
            status = error.localizedDescription
        }
    }

    func mergeBlindTracks(_ trackIDs: Set<String>) {
        guard let preview = registrationProject?.blindTrackReviewPreview else {
            status = "Build the blind 3D track review before merging tracks"
            return
        }
        do {
            let state = try BlindTrackReviewEditor.merge(preview: preview, trackIDs: trackIDs)
            applyBlindTrackReviewState(state, action: "Merged blind tracks")
        } catch {
            status = error.localizedDescription
        }
    }

    func reassignBlindSourcePoints(_ sourcePointIDs: Set<String>, to targetTrackID: String?) {
        guard let preview = registrationProject?.blindTrackReviewPreview else {
            status = "Build the blind 3D track review before reassigning source points"
            return
        }
        do {
            let state = try BlindTrackReviewEditor.reassign(
                preview: preview,
                sourcePointIDs: sourcePointIDs,
                targetTrackID: targetTrackID
            )
            applyBlindTrackReviewState(
                state,
                action: targetTrackID == nil
                    ? "Moved source points to unassigned"
                    : "Reassigned source points"
            )
        } catch {
            status = error.localizedDescription
        }
    }

    func resetBlindTrackMembership() {
        guard var project = registrationProject, project.blindReviewLocked == false else {
            status = "Unlock blind review before resetting observed-track membership"
            return
        }
        project.blindTrackReview = nil
        project.blindTrackReviewPreview = nil
        project.updatedAt = Date()
        registrationProject = project
        persistRegistrationProject()
        status = "Reset manual 3D membership · rebuild to restore deterministic blind RANSAC"
    }

    private func applyBlindTrackReviewState(_ state: BlindTrackReviewState, action: String) {
        guard var project = registrationProject, project.blindReviewLocked == false else {
            status = "Unlock blind review before editing observed tracks"
            return
        }
        project.blindTrackReview = state
        project.blindTrackReviewPreview = nil
        project.updatedAt = Date()
        registrationProject = project
        status = "\(action) · validating deterministic blind refit..."
        buildBlindTrackReview()
    }

    private func clearBlindTrackMembershipAfterSliceEdit() {
        guard var project = registrationProject else { return }
        project.blindTrackReview = nil
        project.blindTrackReviewPreview = nil
        project.updatedAt = Date()
        registrationProject = project
        persistRegistrationProject()
    }

    func lockBlindTrackReview() {
        guard requireCurrentDatasetFingerprint(
            before: "locking blind registration and track review"
        ) else { return }
        guard var project = registrationProject else {
            status = "No registration project is loaded"
            return
        }
        guard let state = project.blindTrackReview,
              let preview = project.blindTrackReviewPreview,
              preview.passesRetrospectiveBoundary,
              state == preview.asEditableState else {
            status = "Build and validate the complete blind 3D track partition before locking review"
            return
        }
        let unresolved = project.acceptedSlices.flatMap { slice in
            slice.effectiveProbeTrackCandidates.filter {
                $0.reviewAccepted != true && $0.status != "rejected"
            }
        }
        guard unresolved.isEmpty else {
            status = "Review every detected blind track candidate before locking the blind result"
            return
        }
        project.blindReviewLocked = true
        if var context = project.brain3dContext {
            context.blindReviewLocked = true
            context.reviewPreview = nil
            context.reviewDispositions = []
            project.brain3dContext = context
        }
        project.updatedAt = Date()
        registrationProject = project
        persistRegistrationProject()
        status = "Locked blind registration and track review · Brain3D overlays may now be revealed"
    }

    func unlockBlindTrackReview() {
        guard var project = registrationProject else { return }
        project.blindReviewLocked = false
        if var context = project.brain3dContext {
            context.blindReviewLocked = false
            context.reviewDispositions = []
            context.reviewPreview = nil
            project.brain3dContext = context
        }
        project.updatedAt = Date()
        registrationProject = project
        persistRegistrationProject()
        status = "Unlocked blind review · Brain3D overlays are hidden until it is locked again"
    }

    func buildBrain3DMatchReview() {
        guard requireCurrentDatasetFingerprint(
            before: "building Brain3D retrospective review"
        ) else { return }
        guard !isBusy else {
            status = "Wait for the current operation before building Brain3D review"
            return
        }
        guard let project = registrationProject,
              project.brain3dContext?.blindReviewLocked == true else {
            status = "Lock blind registration and track review before revealing Brain3D context"
            return
        }
        let outputURL = defaultRegistrationWorkerFolder()
        runRegistrationWorker(
            "Reconstructing blind tracks for post-lock Brain3D review...",
            operation: {
                try RegistrationWorkerService().reviewBrain3D(
                    project: project,
                    outputURL: outputURL
                )
            },
            onSuccess: { [weak self] result in
                guard let self,
                      let preview = result.brain3DReviewPreview else { return }
                self.applyBrain3DReviewPreview(preview, requestedProject: project)
            }
        )
    }

    @discardableResult
    func applyBrain3DReviewPreview(
        _ preview: Brain3DReviewPreview,
        requestedProject: RegistrationProject
    ) -> Bool {
        guard preview.schemaVersion == 1,
              preview.usableForNavigation == false,
              preview.tracks.allSatisfy({ $0.usableForNavigation == false }),
              preview.tracks.allSatisfy({
                  $0.leaveOneSectionOutSensitivity.usableForNavigation == false
              }),
              preview.plannedShanks.allSatisfy({ $0.usableForNavigation == false }),
              preview.roiSummaries.allSatisfy({ $0.usableForNavigation == false }),
              var updated = registrationProject,
              updated == requestedProject,
              var context = updated.brain3dContext,
              context.blindReviewLocked,
              updated.blindReviewLocked else {
            status = "Ignored stale Brain3D review because the project or handoff changed"
            return false
        }
        context.reviewPreview = preview
        context.reviewDispositions = []
        updated.brain3dContext = context
        updated.updatedAt = Date()
        registrationProject = updated
        persistRegistrationProject()
        status = "Built Brain3D review · every observed track and planned shank needs manual confirmation"
        return true
    }

    func confirmBrain3DSuggestion(
        _ suggestion: Brain3DReviewSuggestion,
        reviewerLabel: String,
        reason: String
    ) {
        let state: Brain3DTrackDisposition.State = suggestion.shankId == nil
            ? .insertionLevelAmbiguous
            : .exactShank
        setBrain3DDisposition(
            state: state,
            trackID: suggestion.trackId,
            insertionSnapshotID: suggestion.insertionSnapshotId,
            shankID: suggestion.shankId,
            reviewerLabel: reviewerLabel,
            reason: reason
        )
    }

    func markBrain3DTrackUnmatched(
        _ trackID: String,
        reviewerLabel: String,
        reason: String
    ) {
        setBrain3DDisposition(
            state: .observedUnmatched,
            trackID: trackID,
            insertionSnapshotID: nil,
            shankID: nil,
            reviewerLabel: reviewerLabel,
            reason: reason
        )
    }

    func markBrain3DShankNotObserved(
        _ shank: Brain3DPlannedShankReview,
        reviewerLabel: String,
        reason: String
    ) {
        setBrain3DDisposition(
            state: .plannedNotObserved,
            trackID: nil,
            insertionSnapshotID: shank.insertionSnapshotId,
            shankID: shank.shankId,
            reviewerLabel: reviewerLabel,
            reason: reason
        )
    }

    func clearBrain3DDisposition(_ dispositionID: String) {
        guard var project = registrationProject,
              var context = project.brain3dContext else { return }
        context.reviewDispositions.removeAll { $0.id == dispositionID }
        project.brain3dContext = context
        project.updatedAt = Date()
        registrationProject = project
        persistRegistrationProject()
    }

    private func setBrain3DDisposition(
        state: Brain3DTrackDisposition.State,
        trackID: String?,
        insertionSnapshotID: String?,
        shankID: String?,
        reviewerLabel: String,
        reason: String
    ) {
        let reviewer = reviewerLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let explanation = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reviewer.isEmpty, !explanation.isEmpty else {
            status = "Manual Brain3D dispositions require a reviewer label and reason"
            return
        }
        guard var project = registrationProject,
              var context = project.brain3dContext,
              context.reviewPreview != nil else {
            status = "Build the post-lock Brain3D review first"
            return
        }
        if let trackID {
            context.reviewDispositions.removeAll { $0.trackId == trackID }
        }
        if let insertionSnapshotID, let shankID {
            context.reviewDispositions.removeAll {
                $0.insertionSnapshotId == insertionSnapshotID
                    && $0.shankId == shankID
            }
        } else if state == .insertionLevelAmbiguous, let insertionSnapshotID {
            context.reviewDispositions.removeAll {
                $0.state == .plannedNotObserved
                    && $0.insertionSnapshotId == insertionSnapshotID
            }
        }
        context.reviewDispositions.append(
            Brain3DTrackDisposition(
                id: UUID().uuidString.lowercased(),
                state: state,
                trackId: trackID,
                insertionSnapshotId: insertionSnapshotID,
                shankId: shankID,
                reviewerLabel: reviewer,
                reason: explanation,
                confirmedAt: Date()
            )
        )
        project.brain3dContext = context
        project.updatedAt = Date()
        registrationProject = project
        persistRegistrationProject()
        status = context.manualReviewBlockers.isEmpty
            ? "Brain3D retrospective match review is complete"
            : "Saved manual disposition · review remains incomplete"
    }

    func toggleSelectedPoseLock() {
        guard !isRunningRegistrationWorker else {
            status = "Wait for registration to finish before editing pose state"
            return
        }
        guard registrationProject?.blindReviewLocked != true else {
            status = "Unlock blind review before changing a pose"
            return
        }
        guard var slice = selectedRegistrationSlice else {
            status = "No registration slice selected"
            return
        }
        guard slice.hasWorkerEstimatedPose, var pose = slice.pose else {
            status = "Run Pose before locking an atlas plane"
            return
        }
        pose.manuallyLocked.toggle()
        pose.provenance = pose.manuallyLocked ? "Manually locked by reviewer" : "Unlocked by reviewer"
        recordRegistrationReviewUndo(
            records: [slice],
            buttonTitle: pose.manuallyLocked ? "Undo Lock" : "Undo Unlock",
            statusMessage: "Undid pose edit for \(slice.title)"
        )
        slice.pose = pose
        slice.status = .needsReview
        replaceRegistrationSlice(slice, preservingReviewUndo: true)
        status = pose.manuallyLocked ? "Locked \(slice.title) pose" : "Unlocked \(slice.title) pose"
    }

    func rotateSelectedRegistrationSlice180() {
        guard !isRunningRegistrationWorker else {
            status = "Wait for registration to finish before changing orientation"
            return
        }
        guard registrationProject?.blindReviewLocked != true else {
            status = "Unlock blind review before changing section orientation"
            return
        }
        guard var slice = selectedRegistrationSlice,
              slice.hasWorkerEstimatedPose,
              var pose = slice.pose else {
            status = "Run Pose before correcting section orientation"
            return
        }

        let current = Int(pose.rotationDegrees.rounded()).quotientAndRemainder(dividingBy: 360).remainder
        pose.rotationDegrees = Double(current == 180 || current == -180 ? 0 : 180)
        pose.manuallyLocked = true
        pose.provenance = "Reviewer set source orientation to \(Int(pose.rotationDegrees)) degrees"
        recordRegistrationReviewUndo(
            records: [slice],
            buttonTitle: "Undo Rotate",
            statusMessage: "Restored the prior orientation for \(slice.title)"
        )

        slice.pose = pose
        slice.status = .poseEstimated
        slice.transformChain.transforms = slice.transformChain.transforms.compactMap { transform in
            guard transform.kind == .pose else { return nil }
            var transform = transform
            transform.metric = pose.sourceConfidence
            transform.provenance = pose.provenance
            transform.createdAt = Date()
            transform.rasterOrientation = RasterOrientation(
                rotationDegrees: Int(pose.rotationDegrees.rounded()),
                flipHorizontal: pose.flipHorizontal,
                flipVertical: pose.flipVertical
            )
            return transform
        }
        if var artifacts = slice.artifacts {
            if let rawStructural = artifacts.rawStructuralImagePath {
                artifacts.preparedImagePath = rawStructural
                artifacts.structuralImagePath = rawStructural
            }
            if let rawProbe = artifacts.rawProbeChannelImagePath {
                artifacts.probeChannelImagePath = rawProbe
            }
            if let rawOverlay = artifacts.rawSourceOverlayImagePath {
                artifacts.sourceOverlayImagePath = rawOverlay
            }
            artifacts.tissueMaskPath = nil
            artifacts.atlasReferencePath = nil
            artifacts.registeredImagePath = nil
            artifacts.overlayImagePath = nil
            artifacts.boundaryImagePath = nil
            artifacts.checkerboardImagePath = nil
            artifacts.differenceImagePath = nil
            artifacts.annotationImagePath = nil
            artifacts.transformPath = nil
            artifacts.trackMaskPath = nil
            artifacts.trackOverlayPath = nil
            artifacts.atlasAPIndex = nil
            slice.artifacts = artifacts
        }
        slice.canonicalRasterOrientation = nil
        slice.probeTrack = nil
        slice.probeTrackCandidates = []
        slice.qc.majorRegionIoU = nil
        slice.qc.mutualInformationMetric = nil
        slice.qc.landmarkRMSErrorMicrons = nil
        slice.qc.warnings.removeAll { $0.hasPrefix("Affine ") }
        slice.qc.warnings.append("Orientation changed; rerun affine registration before acceptance.")
        slice.reviewNotes = "Orientation corrected by reviewer; downstream registration invalidated."
        replaceRegistrationSlice(slice, preservingReviewUndo: true)
        status = "Rotated \(slice.title) to \(Int(pose.rotationDegrees))° · run Affine to update the overlay"
    }

    func exportAtlasWithPanel() {
        guard requireCurrentDatasetFingerprint(
            before: "exporting retrospective atlas evidence"
        ) else { return }
        guard !isBusy else {
            status = "Wait for the current operation to finish before exporting"
            return
        }
        guard let project = registrationProject else {
            status = "No registration project to export"
            return
        }
        let blockers = project.blockersForAtlasExport
        guard blockers.isEmpty else {
            status = "Atlas export blocked: \(blockers.joined(separator: " "))"
            lastWorkerResult = RegistrationWorkerResult(
                command: RegistrationWorkerCommand.exportAtlas.rawValue,
                stage: .blocked,
                projectID: project.id,
                outputPath: nil,
                messages: blockers,
                project: project,
                slice: nil,
                export: nil
            )
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Allen CCF registration"
        panel.nameFieldStringValue = "BrainBuilderAtlasExport"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            runRegistrationWorker("Exporting atlas registration...") {
                try RegistrationWorkerService().exportAtlas(project: project, outputURL: url)
            }
        }
    }

    func cancelRegistrationWorker() {
        guard isRunningRegistrationWorker, !isCancelingRegistrationWorker else {
            return
        }
        isCancelingRegistrationWorker = true
        status = "Canceling registration..."
        registrationTask?.cancel()
    }

    #if DEBUG
    func installRegistrationWorkerStateForTesting(isRunning: Bool, isCanceling: Bool = false) {
        isRunningRegistrationWorker = isRunning
        isCancelingRegistrationWorker = isCanceling
        registrationTask = nil
    }
    #endif

    func updateChannelRole(channelIndex: Int, role: RegistrationChannelRole) {
        guard !isRunningRegistrationWorker else {
            status = "Wait for registration to finish before changing channel roles"
            return
        }
        guard var project = registrationProject,
              let index = project.channelMappings.firstIndex(where: { $0.channelIndex == channelIndex }) else {
            status = "No registration channel selected"
            return
        }

        guard project.channelMappings[index].role != role else {
            return
        }
        if role == .structural || role == .probeTrack {
            for otherIndex in project.channelMappings.indices
            where otherIndex != index && project.channelMappings[otherIndex].role == role {
                project.channelMappings[otherIndex].role = .signal
            }
        }
        project.channelMappings[index].role = role
        let channelName = project.channelMappings[index].name
        if let dataset, let baseVolume = unfilteredVolume {
            let reviewed = makeReviewedVolume(from: baseVolume, dataset: dataset)
            var fresh = registrationWorker.makeProject(
                dataset: dataset,
                volume: reviewed,
                channelMappings: project.channelMappings
            )
            fresh.id = project.id
            fresh.createdAt = project.createdAt
            fresh.updatedAt = Date()
            project = fresh

            registrationReviewUndoSnapshot = nil
            registrationProject = refreshStructuralChannelWarnings(in: project)
            volume = nil
            sectionOrientationState = .pending
            if let fingerprint = project.provenance?.datasetFingerprint {
                pendingSectionOrientation = PendingSectionOrientation(
                    scanGeneration: scanGeneration,
                    buildGeneration: buildGeneration,
                    datasetRootPath: dataset.rootURL.path,
                    datasetFingerprint: fingerprint,
                    project: project,
                    reviewedVolume: reviewed,
                    savedProjectURL: persistentRegistrationProjectURL(for: dataset, mode: project.sourceMode)
                )
            }
            persistRegistrationProject()
            status = "Set \(channelName) to \(role.title); estimating orientation again"
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.beginInitialSectionOrientation()
            }
            return
        } else {
            project.slices = project.slices.map { slice in
                var slice = slice
                let prior = SlicePose.estimated(
                    apMicrons: slice.pose?.atlasAPMicrons ?? 0,
                    confidence: 0,
                    provenance: "Channel mapping changed; Prepare and Pose must run again"
                )
                slice.status = .unprepared
                slice.pose = prior
                slice.transformChain = TransformChain(
                    direction: .atlasToSlice,
                    transforms: [.posePrior(prior)]
                )
                slice.artifacts = nil
                slice.probeTrack = nil
                slice.qc.majorRegionIoU = nil
                slice.qc.mutualInformationMetric = nil
                return slice
            }
            project.updatedAt = Date()
        }
        registrationReviewUndoSnapshot = nil
        registrationProject = refreshStructuralChannelWarnings(in: project)
        volume = nil
        sectionOrientationState = .pending
        persistRegistrationProject()
        status = "Set \(channelName) to \(role.title); previous registration was invalidated"
    }

    func export(volume: BrainVolume, dataset: BrainDataset, to folderURL: URL) {
        exportGeneration += 1
        let generation = exportGeneration
        exportTask?.cancel()
        isExporting = true
        status = "Exporting OBJ reconstruction..."

        let task = Task.detached(priority: .userInitiated) {
            try VolumeExportService().export(volume: volume, dataset: dataset, to: folderURL)
        }
        exportTask = task

        Task { @MainActor in
            do {
                let result = try await task.value
                guard generation == exportGeneration else {
                    return
                }
                lastExportResult = result
                status = "Exported OBJ reconstruction to \(result.folderURL.path)"
                NSWorkspace.shared.activateFileViewerSelecting([result.objURL])
            } catch is CancellationError {
                if generation == exportGeneration {
                    status = "Export canceled"
                }
            } catch {
                if generation == exportGeneration {
                    status = "Export failed: \(error.localizedDescription)"
                }
            }

            if generation == exportGeneration {
                isExporting = false
                exportTask = nil
            }
        }
    }

    var isBusy: Bool {
        isScanning || isBuildingVolume || isExporting || isRunningRegistrationWorker
    }

    var completedAutoRegistrationSummary: RegistrationCompletionSummary? {
        Self.completedAutoRegistrationSummary(
            progress: registrationProgress,
            result: lastWorkerResult,
            project: registrationProject
        )
    }

    nonisolated static func completedAutoRegistrationSummary(
        progress: RegistrationWorkerProgress?,
        result: RegistrationWorkerResult?,
        project: RegistrationProject?
    ) -> RegistrationCompletionSummary? {
        guard let progress,
              progress.isValid,
              progress.command == RegistrationWorkerCommand.registerProject.rawValue,
              progress.stage == .completed,
              progress.completed == progress.total,
              let result,
              result.command == RegistrationWorkerCommand.registerProject.rawValue,
              result.stage == .ok,
              let completedProject = result.project,
              let project,
              completedProject.id == project.id,
              result.projectID == nil || result.projectID == completedProject.id,
              completedProject.datasetRootPath == project.datasetRootPath,
              completedProject.atlas == project.atlas,
              completedProject.sourceMode == project.sourceMode,
              completedProject == project,
              completedProject.hasCompleteCanonicalSectionOrientation,
              completedProject.slices.map(\.id).sorted() == project.slices.map(\.id).sorted(),
              progress.total == completedProject.slices.count,
              progress.failed == completedProject.slices.filter({ $0.status == .failed }).count else {
            return nil
        }
        return RegistrationCompletionSummary(project: project)
    }

    var canExportAtlas: Bool {
        registrationProject?.blockersForAtlasExport.isEmpty == true && !isBusy
    }

    var selectedGroup: BrainGroup? {
        guard let selectedGroupID else {
            return dataset?.groups.first
        }
        return dataset?.groups.first { $0.id == selectedGroupID }
    }

    var selectedVolumeSlice: VolumeSlice? {
        guard let selectedSliceID else {
            return volume?.slices.first
        }
        return volume?.slices.first { $0.id == selectedSliceID }
    }

    var selectedVolumeSliceIndex: Int? {
        guard let slices = volume?.slices, !slices.isEmpty else {
            return nil
        }
        guard let selectedSliceID else {
            return 0
        }
        return slices.firstIndex { $0.id == selectedSliceID }
    }

    var canExcludeVolumeSlice: Bool {
        reviewedSliceCount > 1 && !isBusy
    }

    var canRestoreExcludedVolumeSlices: Bool {
        !excludedSliceIDs.isEmpty && !isBusy
    }

    var canUndoVolumeSliceExclusion: Bool {
        guard let lastID = exclusionHistory.last else {
            return false
        }
        return excludedSliceIDs.contains(lastID) && !isBusy
    }

    var undoVolumeSliceExclusionTitle: String? {
        guard let lastID = exclusionHistory.last else {
            return nil
        }
        return unfilteredVolume?.slices.first { $0.id == lastID }?.title
    }

    var canUndoWorkspaceAction: Bool {
        !isBusy && (registrationReviewUndoSnapshot != nil || canUndoVolumeSliceExclusion)
    }

    var workspaceUndoButtonTitle: String {
        if let snapshot = registrationReviewUndoSnapshot {
            return snapshot.buttonTitle
        }
        return "Undo Exclude"
    }

    var workspaceUndoHelp: String {
        if let snapshot = registrationReviewUndoSnapshot {
            return "\(snapshot.buttonTitle) (⌘Z)"
        }
        if let title = undoVolumeSliceExclusionTitle {
            return "Restore \(title) to the reviewed stack (⌘Z)"
        }
        return "Restore the last excluded section (⌘Z)"
    }

    func undoLastWorkspaceAction() {
        guard !isBusy else {
            status = "Wait for the current operation to finish before undoing"
            return
        }
        guard let snapshot = registrationReviewUndoSnapshot else {
            undoLastVolumeSliceExclusion()
            return
        }
        guard var project = registrationProject else {
            registrationReviewUndoSnapshot = nil
            status = "Review undo is no longer available"
            return
        }

        let previousRecords = Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.id, $0) })
        let restorableIDs = Set(project.slices.map(\.id)).intersection(previousRecords.keys)
        guard restorableIDs.count == previousRecords.count else {
            registrationReviewUndoSnapshot = nil
            status = "Review undo is no longer available for this project"
            return
        }

        if let previousProject = snapshot.project {
            guard previousProject.id == project.id,
                  previousProject.provenance?.datasetFingerprint == project.provenance?.datasetFingerprint else {
                registrationReviewUndoSnapshot = nil
                status = "Correction undo is no longer available for this project"
                return
            }
            project = previousProject
        } else {
            project.slices = project.slices.map { previousRecords[$0.id] ?? $0 }
        }
        project.updatedAt = Date()
        registrationProject = project
        selectedRegistrationSliceID = snapshot.selectedSliceID.flatMap { selectedID in
            project.slices.contains(where: { $0.id == selectedID }) ? selectedID : nil
        } ?? project.slices.first?.id
        synchronizeVolume(with: project)
        registrationReviewUndoSnapshot = nil
        persistRegistrationProject()
        status = snapshot.statusMessage
    }

    func selectVolumeSlice(id: String) {
        guard volume?.slices.contains(where: { $0.id == id }) == true else {
            return
        }
        selectedSliceID = id
    }

    func moveSelectedVolumeSlice(by offset: Int) {
        guard offset != 0,
              let slices = volume?.slices,
              let selectedVolumeSliceIndex else {
            return
        }
        let targetIndex = selectedVolumeSliceIndex + offset
        guard slices.indices.contains(targetIndex) else {
            return
        }
        selectedSliceID = slices[targetIndex].id
    }

    var selectedRegistrationSlice: SliceRegistrationRecord? {
        guard let selectedRegistrationSliceID else {
            return registrationProject?.slices.first
        }
        return registrationProject?.slices.first { $0.id == selectedRegistrationSliceID }
    }

    func volumeSlice(forRegistrationSliceID id: String?) -> VolumeSlice? {
        guard let id else {
            return nil
        }
        return volume?.slices.first { $0.id == id }
    }

    var atlasExportBlockers: [String] {
        registrationProject?.blockersForAtlasExport ?? ["No registration project loaded."]
    }

    var reviewedSliceCount: Int {
        volume?.slices.count ?? pendingSectionOrientation?.reviewedVolume.slices.count ?? 0
    }

    var detectedSliceCount: Int {
        unfilteredVolume?.slices.count ?? volume?.slices.count ?? 0
    }

    var canRetrySectionOrientation: Bool {
        pendingSectionOrientation != nil && !isBusy
    }

    private func recordRegistrationReviewUndo(
        records: [SliceRegistrationRecord],
        buttonTitle: String,
        statusMessage: String,
        project: RegistrationProject? = nil
    ) {
        registrationReviewUndoSnapshot = RegistrationReviewUndoSnapshot(
            records: records,
            selectedSliceID: selectedRegistrationSliceID,
            buttonTitle: buttonTitle,
            statusMessage: statusMessage,
            project: project
        )
    }

    private func replaceRegistrationSlice(
        _ slice: SliceRegistrationRecord,
        preservingReviewUndo: Bool = false
    ) {
        guard var project = registrationProject,
              let index = project.slices.firstIndex(where: { $0.id == slice.id }) else {
            return
        }
        if !preservingReviewUndo {
            registrationReviewUndoSnapshot = nil
        }
        project.slices[index] = slice
        project.updatedAt = Date()
        registrationProject = project
        selectedRegistrationSliceID = slice.id
        synchronizeVolume(with: project)
        persistRegistrationProject()
    }

    private func publishVerifiedRegistrationProject(_ project: RegistrationProject) {
        guard let activeProject = registrationProject,
              let currentVolume = volume,
              project.id == activeProject.id,
              normalizedFileURL(URL(fileURLWithPath: project.datasetRootPath))
                == normalizedFileURL(URL(fileURLWithPath: activeProject.datasetRootPath)),
              project.sourceMode == activeProject.sourceMode,
              project.provenance?.datasetFingerprint == activeProject.provenance?.datasetFingerprint,
              project.slices.map(\.id) == activeProject.slices.map(\.id),
              project.hasCompleteCanonicalSectionOrientation else {
            status = "Worker output did not contain a complete verified DeepSlice orientation; the current project was kept unchanged"
            return
        }
        guard let canonical = canonicalizedVolume(currentVolume, with: project) else {
            status = "Worker output orientation could not be applied to every section raster; the current project was kept unchanged"
            return
        }
        guard let dataset else {
            status = "Worker output was verified, but the active dataset is no longer available; the current project was kept unchanged"
            return
        }
        guard canPersistRegistrationProject(
            at: persistentRegistrationProjectURL(for: dataset, mode: project.sourceMode)
        ) else { return }
        do {
            try registrationWorker.write(
                project,
                to: persistentRegistrationProjectURL(for: dataset, mode: project.sourceMode)
            )
        } catch {
            status = "Verified worker output could not be saved; the current project was kept unchanged: \(error.localizedDescription)"
            return
        }

        registrationReviewUndoSnapshot = nil
        registrationProject = project
        volume = canonical
        selectedRegistrationSliceID = selectedRegistrationSliceID.flatMap { id in
            project.slices.contains(where: { $0.id == id }) ? id : nil
        } ?? project.slices.first?.id
        sectionOrientationState = .ready
    }

    private func synchronizeVolume(with project: RegistrationProject) {
        guard project.sourceMode == .montageSections else { return }
        guard project.hasCompleteCanonicalSectionOrientation else {
            volume = nil
            sectionOrientationState = .pending
            return
        }
        guard let currentVolume = volume,
              let canonical = canonicalizedVolume(currentVolume, with: project) else {
            volume = nil
            sectionOrientationState = .unavailable(
                "Canonical orientation could not be applied atomically to every section raster; raw sections remain hidden"
            )
            return
        }
        volume = canonical
        sectionOrientationState = .ready
    }

    private func canonicalizedVolume(
        _ input: BrainVolume,
        with project: RegistrationProject
    ) -> BrainVolume? {
        guard project.hasCompleteCanonicalSectionOrientation,
              input.slices.map(\.id) == project.slices.map(\.id) else {
            return nil
        }
        let output = synchronizedVolume(input, with: project)
        let records = Dictionary(uniqueKeysWithValues: project.slices.map { ($0.id, $0) })
        guard output.slices.allSatisfy({ slice in
            guard let pose = records[slice.id]?.pose,
                  let expectedRotation = canonicalRotationDegrees(pose.rotationDegrees),
                  let actualRotation = canonicalRotationDegrees(slice.rotationDegrees) else {
                return false
            }
            return actualRotation == expectedRotation
        }) else {
            return nil
        }
        return output
    }

    private func synchronizedVolume(
        _ input: BrainVolume,
        with project: RegistrationProject
    ) -> BrainVolume {
        var output = input
        let records = Dictionary(uniqueKeysWithValues: project.slices.map { ($0.id, $0) })
        let quantitativePoses = project.slices.compactMap { record -> (String, SlicePose)? in
            guard record.hasWorkerEstimatedPose, let pose = record.pose else { return nil }
            return (record.id, pose)
        }
        let apValues = quantitativePoses.map { $0.1.atlasAPMicrons }
        let minAP = apValues.min()
        let maxAP = apValues.max()
        let centerAP = minAP.flatMap { minimum in maxAP.map { (minimum + $0) / 2 } }
        let sceneMicronsPerUnit = medianValue(
            output.slices.compactMap { slice in
                guard let width = slice.physicalWidthMicrons, width > 0 else { return nil }
                return width
            }
        )
        let sceneDepth = AllenCCFReference.default.sceneDepth

        for index in output.slices.indices {
            output.slices[index].atlasPlacement = nil
            guard let record = records[output.slices[index].id],
                  record.hasWorkerEstimatedPose,
                  let pose = record.pose else {
                continue
            }
            guard let targetRotation = canonicalRotationDegrees(pose.rotationDegrees),
                  let currentRotation = canonicalRotationDegrees(output.slices[index].rotationDegrees),
                  !pose.flipHorizontal,
                  !pose.flipVertical,
                  targetRotation == 0 || targetRotation == 180 else {
                output.slices[index].registration.method =
                    "Worker pose uses an unsupported 3D raster orientation; review required"
                continue
            }
            let delta = abs(targetRotation - currentRotation) % 360
            if delta == 180 {
                guard let rotatedTexture = ImageProcessingService.rotated180(output.slices[index].texture) else {
                    output.slices[index].registration.method =
                        "Canonical raster rotation failed; raw section withheld"
                    continue
                }
                var rotatedChannels: [VolumeChannelImage] = []
                var channelRotationFailed = false
                for sourceChannel in output.slices[index].channelImages {
                    guard let rotated = ImageProcessingService.rotated180(sourceChannel.texture) else {
                        channelRotationFailed = true
                        break
                    }
                    var channel = sourceChannel
                    channel.texture = rotated
                    rotatedChannels.append(channel)
                }
                guard !channelRotationFailed,
                      rotatedChannels.count == output.slices[index].channelImages.count else {
                    output.slices[index].registration.method =
                        "Canonical channel rotation failed; raw section withheld"
                    continue
                }

                output.slices[index].texture = rotatedTexture
                output.slices[index].channelImages = rotatedChannels
                output.slices[index].offsetX *= -1
                output.slices[index].offsetY *= -1
                let imageWidth = CGFloat(output.slices[index].signal.imageSize.width)
                let imageHeight = CGFloat(output.slices[index].signal.imageSize.height)
                let oldBounds = output.slices[index].signal.tissueBounds
                output.slices[index].signal.tissueBounds = CGRect(
                    x: imageWidth - oldBounds.maxX,
                    y: imageHeight - oldBounds.maxY,
                    width: oldBounds.width,
                    height: oldBounds.height
                )
            }
            output.slices[index].rotationDegrees = Double(targetRotation)
            output.slices[index].registration.atlasAPMicrons = pose.atlasAPMicrons
            output.slices[index].registration.atlasAPIndex10um = Int(round(pose.atlasAPMicrons / 10))
            output.slices[index].registration.confidence = pose.sourceConfidence
            output.slices[index].registration.method = pose.atlasAnchoring?.count == 9
                ? "DeepSlice pose synchronized"
                : "Atlas pose synchronized; quantitative 3D plane unavailable"
            if let centerAP, let sceneMicronsPerUnit, sceneMicronsPerUnit > 0 {
                output.slices[index].z = (pose.atlasAPMicrons - centerAP) / sceneMicronsPerUnit
                output.slices[index].atlasPlacement = atlasPlacement(
                    for: record,
                    pose: pose,
                    centerAPMicrons: centerAP,
                    sceneMicronsPerUnit: sceneMicronsPerUnit
                )
                if let placement = output.slices[index].atlasPlacement {
                    output.slices[index].registration.method = placement.isReviewed
                        ? "DeepSlice plane + SimpleITK affine applied to 3D, reviewed"
                        : "DeepSlice plane + SimpleITK affine applied to 3D, review required"
                }
            } else if let minAP, let maxAP, maxAP > minAP {
                let fraction = (pose.atlasAPMicrons - minAP) / (maxAP - minAP)
                output.slices[index].z = (fraction - 0.5) * sceneDepth
            }
        }
        output.bounds = bounds(for: output.slices)
        output.revision = UUID()
        return output
    }

    private func canonicalRotationDegrees(_ degrees: Double) -> Int? {
        guard degrees.isFinite else { return nil }
        let rounded = Int(degrees.rounded())
        guard abs(degrees - Double(rounded)) < 0.001 else { return nil }
        let normalized = ((rounded % 360) + 360) % 360
        return normalized == 0 || normalized == 180 ? normalized : nil
    }

    private func atlasPlacement(
        for record: SliceRegistrationRecord,
        pose: SlicePose,
        centerAPMicrons: Double,
        sceneMicronsPerUnit: Double
    ) -> AtlasSlicePlacement? {
        guard record.transformChain.hasUsableQuantitativeTransform,
              let sliceToAtlasPlane = record.transformChain.invertedAffineComposite(),
              let pixelSizeMicrons = record.pixelSizeMicrons,
              pixelSizeMicrons > 0,
              let anchoring = pose.atlasAnchoring,
              anchoring.count == 9,
              anchoring.allSatisfy(\.isFinite) else {
            return nil
        }

        let atlas = AllenCCFReference.default
        let dimensions = atlas.dimensionsVoxels
        let quickNIIOrigin = SIMD3<Double>(anchoring[0], anchoring[1], anchoring[2])
        let quickNIIU = SIMD3<Double>(anchoring[3], anchoring[4], anchoring[5])
        let quickNIIV = SIMD3<Double>(anchoring[6], anchoring[7], anchoring[8])
        let atlasOrigin = SIMD3<Double>(
            Double(dimensions.x - 1) - quickNIIOrigin.y,
            Double(dimensions.y - 1) - quickNIIOrigin.z,
            Double(dimensions.z - 1) - quickNIIOrigin.x
        )
        let atlasU = SIMD3<Double>(-quickNIIU.y, -quickNIIU.z, -quickNIIU.x)
        let atlasV = SIMD3<Double>(-quickNIIV.y, -quickNIIV.z, -quickNIIV.x)

        let resolution = SIMD3<Double>(
            atlas.voxelSizeMicrons,
            atlas.voxelSizeMicrons,
            atlas.voxelSizeMicrons
        )
        let center = SIMD3<Double>(
            centerAPMicrons,
            Double(dimensions.y - 1) * atlas.voxelSizeMicrons / 2,
            Double(dimensions.z - 1) * atlas.voxelSizeMicrons / 2
        )
        return AtlasSlicePlacement(
            sliceToAtlasPlane: sliceToAtlasPlane,
            pixelSizeMicrons: pixelSizeMicrons,
            planeSize: record.imageSize,
            atlasOriginIndex: atlasOrigin,
            atlasUIndex: atlasU,
            atlasVIndex: atlasV,
            atlasResolutionMicrons: resolution,
            atlasCenterMicrons: center,
            sceneMicronsPerUnit: sceneMicronsPerUnit,
            isReviewed: record.status == .accepted
        )
    }

    private func medianValue(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private func reviewedProjectByMergingArchivedSlices() -> RegistrationProject? {
        guard let dataset,
              let fingerprint = registrationProject?.provenance?.datasetFingerprint else {
            return registrationProject
        }
        let state = ReviewedStackState(
            datasetRootPath: dataset.rootURL.path,
            sourceMode: sourceMode,
            datasetFingerprint: fingerprint,
            excludedSliceIDs: Array(excludedSliceIDs),
            exclusionHistory: exclusionHistory,
            archivedRegistrationSlices: Array(archivedRegistrationSlices.values)
        )
        return state.mergingArchivedSlices(into: registrationProject)
    }

    private func installReviewedVolume(
        from baseVolume: BrainVolume,
        dataset: BrainDataset,
        preservingChannelRolesFrom existingProject: RegistrationProject?,
        statusMessage: String
    ) {
        registrationReviewUndoSnapshot = nil
        let reviewed = makeReviewedVolume(from: baseVolume, dataset: dataset)
        volume = nil
        selectedSliceID = selectedSliceID.flatMap { id in
            reviewed.slices.contains(where: { $0.id == id }) ? id : nil
        } ?? reviewed.slices.first?.id

        let freshProject = registrationWorker.makeProject(dataset: dataset, volume: reviewed)
        let isExplicitProjectUpdate = existingProject != nil
        let restoredProject = existingProject ?? loadPersistedRegistrationProject(
            for: dataset,
            volume: reviewed,
            expectedFingerprint: freshProject.provenance?.datasetFingerprint
        )
        guard canPersistRegistrationProject(
            at: persistentRegistrationProjectURL(for: dataset, mode: reviewed.sourceMode)
        ) else {
            registrationProject = nil
            pendingSectionOrientation = nil
            sectionOrientationState = .unavailable(status)
            return
        }
        var project = restoredProject.map {
            registrationWorker.makeProject(
                dataset: dataset,
                volume: reviewed,
                channelMappings: $0.channelMappings
            )
        } ?? freshProject
        if let existingProject = restoredProject {
            project.id = existingProject.id
            project.createdAt = existingProject.createdAt
            project.updatedAt = isExplicitProjectUpdate ? Date() : existingProject.updatedAt
            var existingSlices: [String: SliceRegistrationRecord] = [:]
            for record in existingProject.slices where existingSlices[record.id] == nil {
                existingSlices[record.id] = record
            }
            project.slices = project.slices.map { fresh in
                guard var existing = existingSlices[fresh.id] else { return fresh }
                existing.title = fresh.title
                existing.groupID = fresh.groupID
                existing.pixelSizeMicrons = fresh.pixelSizeMicrons
                return existing
            }
            project.atlasAssets = existingProject.atlasAssets
            project.provenance = existingProject.provenance
            project.subjectID = existingProject.subjectID
            project.colonySubjectReceipt = existingProject.colonySubjectReceipt
            if Set(project.slices.map(\.id)) == Set(existingProject.slices.map(\.id)) {
                project.brain3dContext = existingProject.brain3dContext
                project.blindReviewLocked = existingProject.blindReviewLocked
                project.blindTrackReview = existingProject.blindTrackReview
                project.blindTrackReviewPreview = existingProject.blindTrackReviewPreview
            }
        }
        project = refreshStructuralChannelWarnings(in: project)
        registrationProject = project
        selectedRegistrationSliceID = selectedRegistrationSliceID.flatMap { id in
            project.slices.contains(where: { $0.id == id }) ? id : nil
        } ?? project.slices.first?.id

        let exclusionText = excludedSliceIDs.isEmpty ? "" : " (\(excludedSliceIDs.count) excluded)"
        let restorationText = existingProject == nil && restoredProject != nil ? " · restored registration review" : ""
        status = "\(statusMessage)\(exclusionText)\(restorationText)"

        pendingSectionOrientation = nil
        guard reviewed.sourceMode == .montageSections else {
            volume = reviewed
            sectionOrientationState = .notRequired
            if existingProject != nil {
                persistRegistrationProject()
            }
            persistReviewedStackState()
            return
        }

        if project.hasCompleteCanonicalSectionOrientation {
            guard let canonical = canonicalizedVolume(reviewed, with: project) else {
                sectionOrientationState = .unavailable(
                    "Verified worker orientation could not be applied to every section raster; raw sections remain hidden"
                )
                status = sectionOrientationState.detail
                persistReviewedStackState()
                return
            }
            volume = canonical
            sectionOrientationState = .ready
            if existingProject != nil {
                persistRegistrationProject()
            }
            persistReviewedStackState()
            return
        }

        guard project.canAutomaticallyEstimateInitialSectionOrientation,
              let fingerprint = project.provenance?.datasetFingerprint else {
            let fallback = project.provenance?.deepSliceFallbackReason.map { " DeepSlice reported: \($0)" } ?? ""
            sectionOrientationState = .unavailable(
                "The saved project does not contain a complete verified DeepSlice orientation.\(fallback) Raw sections remain hidden."
            )
            status = sectionOrientationState.detail
            persistReviewedStackState()
            return
        }

        pendingSectionOrientation = PendingSectionOrientation(
            scanGeneration: scanGeneration,
            buildGeneration: buildGeneration,
            datasetRootPath: dataset.rootURL.path,
            datasetFingerprint: fingerprint,
            project: project,
            reviewedVolume: reviewed,
            savedProjectURL: persistentRegistrationProjectURL(for: dataset, mode: project.sourceMode)
        )
        sectionOrientationState = .pending
        persistReviewedStackState()
        let expectedScanGeneration = scanGeneration
        let expectedBuildGeneration = buildGeneration
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  self.scanGeneration == expectedScanGeneration,
                  self.buildGeneration == expectedBuildGeneration else {
                return
            }
            self.beginInitialSectionOrientation()
        }
    }

    func retrySectionOrientation() {
        guard !isBusy else { return }
        beginInitialSectionOrientation()
    }

    private func beginInitialSectionOrientation() {
        guard let pending = pendingSectionOrientation,
              pending.scanGeneration == scanGeneration,
              pending.buildGeneration == buildGeneration,
              !isRunningRegistrationWorker else {
            return
        }
        guard canPersistRegistrationProject(at: pending.savedProjectURL) else { return }

        sectionOrientationState = .estimating
        let outputURL = defaultRegistrationWorkerFolder()
        runRegistrationWorker(
            "Preparing sections and estimating canonical orientation...",
            progressOperation: { progress in
                let worker = RegistrationWorkerService()
                progress(
                    RegistrationWorkerProgress(
                        command: RegistrationWorkerCommand.prepare.rawValue,
                        stage: .preparing,
                        completed: 0,
                        total: pending.project.slices.count,
                        message: "Preparing \(pending.project.slices.count) sections for orientation estimation."
                    )
                )
                let prepared = try worker.prepare(
                    project: pending.project,
                    volume: pending.reviewedVolume,
                    outputURL: outputURL,
                    progressHandler: progress
                )
                try Task.checkCancellation()
                guard let preparedProject = prepared.project else {
                    throw RegistrationWorkerError.resultReadFailed("Prepare returned no project")
                }
                return try worker.estimatePose(
                    project: preparedProject,
                    outputURL: outputURL,
                    progressHandler: progress
                )
            },
            onSuccess: { [weak self] result in
                self?.finishInitialSectionOrientation(result, expected: pending)
            },
            onFailure: { [weak self] detail in
                self?.failInitialSectionOrientation(detail, expected: pending)
            },
            onCancel: { [weak self] in
                guard let self,
                      self.pendingSectionOrientation?.datasetFingerprint == pending.datasetFingerprint else {
                    return
                }
                self.sectionOrientationState = .pending
            },
            persistsProjectOnCompletion: false
        )
    }

    private func finishInitialSectionOrientation(
        _ result: RegistrationWorkerResult,
        expected: PendingSectionOrientation
    ) {
        guard let pending = pendingSectionOrientation,
              pending.scanGeneration == expected.scanGeneration,
              pending.buildGeneration == expected.buildGeneration,
              scanGeneration == expected.scanGeneration,
              buildGeneration == expected.buildGeneration,
              pending.datasetFingerprint == expected.datasetFingerprint else {
            return
        }
        guard let dataset,
              normalizedFileURL(dataset.rootURL) == normalizedFileURL(URL(fileURLWithPath: expected.datasetRootPath)),
              let project = result.project,
              project.id == expected.project.id,
              result.projectID == nil || result.projectID == project.id,
              normalizedFileURL(URL(fileURLWithPath: project.datasetRootPath))
                == normalizedFileURL(URL(fileURLWithPath: expected.project.datasetRootPath)),
              project.sourceMode == .montageSections,
              project.provenance?.datasetFingerprint == expected.datasetFingerprint,
              project.slices.map(\.id) == expected.project.slices.map(\.id) else {
            failInitialSectionOrientation(
                "The orientation worker result did not match the active dataset and section set.",
                expected: expected
            )
            return
        }

        guard project.hasCompleteCanonicalSectionOrientation else {
            let fallback = project.provenance?.deepSliceFallbackReason.map { " DeepSlice reported: \($0)" } ?? ""
            failInitialSectionOrientation(
                "The worker did not return a complete verified DeepSlice orientation.\(fallback)",
                expected: expected
            )
            return
        }
        guard let canonical = canonicalizedVolume(expected.reviewedVolume, with: project) else {
            failInitialSectionOrientation(
                "Canonical orientation could not be applied atomically to every section and channel raster.",
                expected: expected
            )
            return
        }

        do {
            guard canPersistRegistrationProject(at: expected.savedProjectURL) else { return }
            try registrationWorker.write(project, to: expected.savedProjectURL)
        } catch {
            failInitialSectionOrientation(
                "Verified orientation could not be saved: \(error.localizedDescription)",
                expected: expected
            )
            return
        }

        registrationReviewUndoSnapshot = nil
        registrationProject = project
        volume = canonical
        selectedSliceID = selectedSliceID.flatMap { id in
            canonical.slices.contains(where: { $0.id == id }) ? id : nil
        } ?? canonical.slices.first?.id
        selectedRegistrationSliceID = selectedRegistrationSliceID.flatMap { id in
            project.slices.contains(where: { $0.id == id }) ? id : nil
        } ?? project.slices.first?.id
        pendingSectionOrientation = nil
        sectionOrientationState = .ready
        persistReviewedStackState()
        status = "Verified canonical orientation for \(project.slices.count) sections with \(project.provenance?.poseEngine ?? "DeepSlice")"
    }

    private func failInitialSectionOrientation(
        _ detail: String,
        expected: PendingSectionOrientation
    ) {
        guard pendingSectionOrientation?.datasetFingerprint == expected.datasetFingerprint,
              scanGeneration == expected.scanGeneration,
              buildGeneration == expected.buildGeneration else {
            return
        }
        volume = nil
        sectionOrientationState = .unavailable("\(detail) Raw sections remain hidden; retry orientation estimation.")
        status = sectionOrientationState.detail
    }

    private func normalizedFileURL(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    private func makeReviewedVolume(from baseVolume: BrainVolume, dataset: BrainDataset) -> BrainVolume {
        let sourceSlices = baseVolume.slices.filter { !excludedSliceIDs.contains($0.id) }
        let spacing = sliceSpacing(in: baseVolume)
        var orderedSlices = sourceSlices.enumerated().map { index, slice in
            var slice = slice
            slice.z = Double(index) * spacing
            return slice
        }

        let atlasRegistered = AtlasRegistrationService().register(orderedSlices, mode: baseVolume.sourceMode)
        orderedSlices = atlasRegistered.slices
        let cortexRegistered = CortexRegistrationService().register(orderedSlices, mode: baseVolume.sourceMode)
        let buildSummary = VolumeBuildSummary(
            sourceImages: baseVolume.buildSummary.sourceImages,
            producedSlices: cortexRegistered.slices.count,
            rejectedComponents: baseVolume.buildSummary.rejectedComponents + excludedSliceIDs.count,
            maxTexturePixels: baseVolume.buildSummary.maxTexturePixels,
            meanForegroundConfidence: meanForegroundConfidence(cortexRegistered.slices),
            meanBackgroundRemoved: meanBackgroundRemoved(cortexRegistered.slices)
        )
        let reliabilityReport = RegistrationReliabilityService().verify(
            dataset: dataset,
            slices: cortexRegistered.slices,
            atlasRegistration: atlasRegistered.summary,
            cortexRegistration: cortexRegistered.summary,
            buildSummary: buildSummary,
            mode: baseVolume.sourceMode
        )

        return BrainVolume(
            sourceMode: baseVolume.sourceMode,
            slices: cortexRegistered.slices,
            bounds: bounds(for: cortexRegistered.slices),
            atlasRegistration: atlasRegistered.summary,
            cortexRegistration: cortexRegistered.summary,
            buildSummary: buildSummary,
            reliabilityReport: reliabilityReport
        )
    }

    private func refreshStructuralChannelWarnings(in project: RegistrationProject) -> RegistrationProject {
        var project = project
        let warning = "No structural channel was detected. Select DAPI, autofluorescence, or another anatomical channel before trusting registration."
        let hasStructuralChannel = !project.structuralChannels.isEmpty

        project.slices = project.slices.map { slice in
            var slice = slice
            if hasStructuralChannel {
                slice.qc.warnings.removeAll { $0 == warning }
            } else if !slice.qc.warnings.contains(warning) {
                slice.qc.warnings.append(warning)
            }
            return slice
        }
        return project
    }

    private func sliceSpacing(in volume: BrainVolume) -> Double {
        guard volume.slices.count > 1 else {
            return 0.12
        }
        let sortedZ = volume.slices.map(\.z).sorted()
        return max(0.001, sortedZ[1] - sortedZ[0])
    }

    private func bounds(for slices: [VolumeSlice]) -> SIMD3<Double> {
        guard !slices.isEmpty else {
            return SIMD3<Double>(0, 0, 0)
        }
        let width = slices.map(\.width).max() ?? 0
        let height = slices.map(\.height).max() ?? 0
        let depth = (slices.map(\.z).max() ?? 0) - (slices.map(\.z).min() ?? 0)
        return SIMD3<Double>(width, height, depth)
    }

    private func meanForegroundConfidence(_ slices: [VolumeSlice]) -> Double {
        guard !slices.isEmpty else {
            return 0
        }
        return slices.map(\.signal.foregroundConfidence).reduce(0, +) / Double(slices.count)
    }

    private func meanBackgroundRemoved(_ slices: [VolumeSlice]) -> Double {
        guard !slices.isEmpty else {
            return 0
        }
        return slices.map(\.signal.backgroundSuppression).reduce(0, +) / Double(slices.count)
    }

    private func runRegistrationWorker(
        _ message: String,
        operation: @escaping @Sendable () throws -> RegistrationWorkerResult,
        onSuccess: ((RegistrationWorkerResult) -> Void)? = nil,
        onFailure: ((String) -> Void)? = nil,
        onCancel: (() -> Void)? = nil,
        persistsProjectOnCompletion: Bool = true
    ) {
        runRegistrationWorker(
            message,
            progressOperation: { _ in try operation() },
            onSuccess: onSuccess,
            onFailure: onFailure,
            onCancel: onCancel,
            persistsProjectOnCompletion: persistsProjectOnCompletion
        )
    }

    private func runRegistrationWorker(
        _ message: String,
        progressOperation: @escaping @Sendable (
            _ progressHandler: @escaping RegistrationWorkerProgressHandler
        ) throws -> RegistrationWorkerResult,
        onSuccess: ((RegistrationWorkerResult) -> Void)? = nil,
        onFailure: ((String) -> Void)? = nil,
        onCancel: (() -> Void)? = nil,
        persistsProjectOnCompletion: Bool = true
    ) {
        registrationGeneration += 1
        let generation = registrationGeneration
        registrationTask?.cancel()
        isRunningRegistrationWorker = true
        isCancelingRegistrationWorker = false
        registrationProgress = nil
        status = message
        let progressHandler: RegistrationWorkerProgressHandler = { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self,
                      generation == self.registrationGeneration,
                      self.isRunningRegistrationWorker,
                      !self.isCancelingRegistrationWorker else {
                    return
                }
                self.registrationProgress = progress
                self.status = progress.message
            }
        }
        let task = Task.detached(priority: .userInitiated) {
            try progressOperation(progressHandler)
        }
        registrationTask = task
        Task { @MainActor in
            do {
                let result = try await task.value
                guard generation == registrationGeneration else {
                    return
                }
                lastWorkerResult = result
                switch result.stage {
                case .ok:
                    status = result.messages.joined(separator: " ")
                    onSuccess?(result)
                    if persistsProjectOnCompletion {
                        persistRegistrationProject()
                    }
                case .blocked:
                    status = "Registration blocked: \(result.messages.joined(separator: " "))"
                    onFailure?(status)
                case .failed:
                    status = "Registration failed: \(result.messages.joined(separator: " "))"
                    onFailure?(status)
                }
            } catch is CancellationError {
                if generation == registrationGeneration {
                    status = "Registration canceled"
                    registrationProgress = nil
                    onCancel?()
                }
            } catch {
                guard generation == registrationGeneration else {
                    return
                }
                status = error.localizedDescription
                registrationProgress = nil
                onFailure?(error.localizedDescription)
            }
            if generation == registrationGeneration {
                isRunningRegistrationWorker = false
                isCancelingRegistrationWorker = false
                registrationTask = nil
            }
        }
    }

    private func persistRegistrationProject() {
        guard let dataset, let project = registrationProject else { return }
        let url = persistentRegistrationProjectURL(for: dataset, mode: project.sourceMode)
        guard canPersistRegistrationProject(at: url) else { return }
        do {
            try registrationWorker.write(project, to: url)
        } catch {
            NSLog("BrainBuilder could not persist registration review: %@", error.localizedDescription)
        }
    }

    /// Fail closed if any source file identity changed after the project was
    /// built.  In particular, this removes the fingerprint-bound Brain3D
    /// subject receipt so an explicit alias rebind must be confirmed again.
    @discardableResult
    private func requireCurrentDatasetFingerprint(before operation: String) -> Bool {
        guard let dataset,
              var project = registrationProject,
              let expectedFingerprint = project.provenance?.datasetFingerprint,
              !expectedFingerprint.isEmpty else {
            status = "A verified source-dataset fingerprint is required before \(operation)"
            return false
        }
        let currentFingerprint = registrationWorker.datasetFingerprint(for: dataset)
        guard currentFingerprint == expectedFingerprint else {
            project.brain3dContext = nil
            project.blindReviewLocked = false
            project.blindTrackReview = nil
            project.blindTrackReviewPreview = nil
            project.updatedAt = Date()
            registrationProject = project
            persistRegistrationProject()
            status = "Source dataset fingerprint changed. Rescan and rebuild registration, then select the Brain3D handoff and confirm any subject rebind again before \(operation)."
            return false
        }
        if let context = project.brain3dContext,
           !context.isBound(toDatasetFingerprint: currentFingerprint) {
            project.brain3dContext = nil
            project.blindReviewLocked = false
            project.updatedAt = Date()
            registrationProject = project
            persistRegistrationProject()
            status = "Brain3D subject binding does not match the current dataset fingerprint. Select the handoff and confirm any subject rebind again before \(operation)."
            return false
        }
        return true
    }

    private func restoreReviewedStackState(for dataset: BrainDataset, baseVolume: BrainVolume) {
        let freshProject = registrationWorker.makeProject(dataset: dataset, volume: baseVolume)
        guard let fingerprint = freshProject.provenance?.datasetFingerprint else {
            excludedSliceIDs = []
            exclusionHistory = []
            archivedRegistrationSlices = [:]
            return
        }

        let validSliceIDs = baseVolume.slices.map(\.id)
        if let state = loadPersistedReviewedStackState(
            for: dataset,
            mode: baseVolume.sourceMode,
            expectedFingerprint: fingerprint,
            validSliceIDs: validSliceIDs
        ) {
            excludedSliceIDs = Set(state.excludedSliceIDs)
            exclusionHistory = state.exclusionHistory
            archivedRegistrationSlices = Dictionary(
                uniqueKeysWithValues: state.archivedRegistrationSlices.map { ($0.id, $0) }
            )
            return
        }

        // Migrate projects written before review-state persistence existed. A
        // strict subset means the missing base slices were previously excluded.
        if let persistedProject = loadPersistedRegistrationProjectCandidate(
            for: dataset,
            mode: baseVolume.sourceMode,
            expectedFingerprint: fingerprint
        ) {
            let persistedIDs = Set(persistedProject.slices.map(\.id))
            let baseIDs = Set(validSliceIDs)
            if !persistedIDs.isEmpty, persistedIDs.isSubset(of: baseIDs), persistedIDs != baseIDs {
                let migratedExclusions = validSliceIDs.filter { !persistedIDs.contains($0) }
                excludedSliceIDs = Set(migratedExclusions)
                exclusionHistory = migratedExclusions
                archivedRegistrationSlices = [:]
                return
            }
        }

        excludedSliceIDs = []
        exclusionHistory = []
        archivedRegistrationSlices = [:]
    }

    private func persistReviewedStackState() {
        guard let dataset,
              let baseVolume = unfilteredVolume,
              let fingerprint = registrationProject?.provenance?.datasetFingerprint else {
            return
        }

        let orderedIDs = baseVolume.slices.map(\.id)
        let state = ReviewedStackState(
            datasetRootPath: dataset.rootURL.path,
            sourceMode: baseVolume.sourceMode,
            datasetFingerprint: fingerprint,
            excludedSliceIDs: orderedIDs.filter(excludedSliceIDs.contains),
            exclusionHistory: exclusionHistory.filter(excludedSliceIDs.contains),
            archivedRegistrationSlices: orderedIDs.compactMap { archivedRegistrationSlices[$0] }
        )
        let url = persistentReviewedStackStateURL(for: dataset, mode: baseVolume.sourceMode)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(state).write(to: url, options: .atomic)
        } catch {
            NSLog("BrainBuilder could not persist reviewed stack state: %@", error.localizedDescription)
        }
    }

    private func loadPersistedReviewedStackState(
        for dataset: BrainDataset,
        mode: StackSourceMode,
        expectedFingerprint: String,
        validSliceIDs: [String]
    ) -> ReviewedStackState? {
        let url = persistentReviewedStackStateURL(for: dataset, mode: mode)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(ReviewedStackState.self, from: data),
              URL(fileURLWithPath: state.datasetRootPath).resolvingSymlinksInPath().standardizedFileURL
                == dataset.rootURL.resolvingSymlinksInPath().standardizedFileURL,
              state.sourceMode == mode,
              state.datasetFingerprint == expectedFingerprint else {
            return nil
        }
        return state.sanitized(validSliceIDs: validSliceIDs)
    }

    private func loadPersistedRegistrationProject(
        for dataset: BrainDataset,
        volume: BrainVolume,
        expectedFingerprint: String?
    ) -> RegistrationProject? {
        guard let project = loadPersistedRegistrationProjectCandidate(
            for: dataset,
            mode: volume.sourceMode,
            expectedFingerprint: expectedFingerprint
        ),
              Set(project.slices.map(\.id)).count == project.slices.count,
              Set(volume.slices.map(\.id)).count == volume.slices.count,
              Set(project.slices.map(\.id)) == Set(volume.slices.map(\.id)) else {
            return nil
        }
        return project
    }

    func loadPersistedRegistrationProjectCandidate(
        for dataset: BrainDataset,
        mode: StackSourceMode,
        expectedFingerprint: String?
    ) -> RegistrationProject? {
        let url = persistentRegistrationProjectURL(for: dataset, mode: mode)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let project: RegistrationProject
        do {
            project = try registrationWorker.readProject(at: url)
        } catch {
            let message = "Saved registration could not be loaded: \(url.path). \(error.localizedDescription) The saved file has been preserved. Restore or repair this file, then reopen the dataset; automatic registration is disabled."
            registrationProjectRestoreFailure = (url, message)
            pendingSectionOrientation = nil
            status = message
            sectionOrientationState = .unavailable(message)
            return nil
        }
        if registrationProjectRestoreFailure?.url == url {
            registrationProjectRestoreFailure = nil
        }
        guard URL(fileURLWithPath: project.datasetRootPath).resolvingSymlinksInPath().standardizedFileURL
                == dataset.rootURL.resolvingSymlinksInPath().standardizedFileURL,
              project.sourceMode == mode,
              project.provenance?.datasetFingerprint != nil,
              project.provenance?.datasetFingerprint == expectedFingerprint else {
            return nil
        }
        return project
    }

    private func canPersistRegistrationProject(at url: URL) -> Bool {
        guard let failure = registrationProjectRestoreFailure, failure.url == url else {
            return true
        }
        status = failure.message
        return false
    }

    private func persistentRegistrationProjectURL(
        for dataset: BrainDataset,
        mode: StackSourceMode
    ) -> URL {
        dataset.rootURL.deletingLastPathComponent()
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent("registration-worker", isDirectory: true)
            .appendingPathComponent("saved-projects", isDirectory: true)
            .appendingPathComponent(
                "\(safeRegistrationFolderName(dataset.rootURL.lastPathComponent))-\(mode.rawValue).json"
            )
    }

    private func persistentReviewedStackStateURL(
        for dataset: BrainDataset,
        mode: StackSourceMode
    ) -> URL {
        persistentRegistrationProjectURL(for: dataset, mode: mode)
            .deletingPathExtension()
            .appendingPathExtension("review.json")
    }

    private func defaultRegistrationWorkerFolder() -> URL {
        let root = dataset?.rootURL.deletingLastPathComponent()
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let projectFolder = safeRegistrationFolderName(
            registrationProject?.id ?? "unassigned-\(dataset?.rootURL.lastPathComponent ?? "dataset")"
        )
        return root
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent("registration-worker", isDirectory: true)
            .appendingPathComponent(projectFolder, isDirectory: true)
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    }

    private func safeRegistrationFolderName(_ value: String) -> String {
        value.replacingOccurrences(of: "[^A-Za-z0-9_.-]", with: "-", options: .regularExpression)
    }
}

enum WorkspaceLocator {
    static func defaultDataFolder() -> URL? {
        let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("data", isDirectory: true)

        if FileManager.default.fileExists(atPath: current.path) {
            return current
        }

        let bundleURL = Bundle.main.bundleURL
        let projectRoot = bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let projectData = projectRoot.appendingPathComponent("data", isDirectory: true)

        if FileManager.default.fileExists(atPath: projectData.path) {
            return projectData
        }

        return nil
    }
}
