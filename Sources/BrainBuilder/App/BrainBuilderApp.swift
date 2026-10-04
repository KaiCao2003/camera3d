import AppKit
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var retainedDelegate: AppDelegate?

    private var window: NSWindow?
    private let store = BrainProjectStore()

    static func main() {
        if runHeadlessCommandIfNeeded() {
            return
        }

        NSLog("BrainBuilder starting NSApplication main")
        let app = NSApplication.shared
        let delegate = AppDelegate()
        retainedDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("BrainBuilder applicationDidFinishLaunching")
        installMainMenu()
        openMainWindow()
        NSApp.activate(ignoringOtherApps: true)

        Task {
            await store.loadDefaultDataIfAvailable()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func openFolderFromMenu() {
        store.openFolderPanel()
    }

    @objc private func rebuildVolumeFromMenu() {
        Task { await store.rebuildVolume() }
    }

    @objc private func exportVolumeFromMenu() {
        store.exportAtlasWithPanel()
    }

    private func openMainWindow() {
        NSLog("BrainBuilder opening main window")
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 820)
        let windowWidth = min(1280, max(980, visibleFrame.width - 80))
        let windowHeight = min(820, max(680, visibleFrame.height - 80))
        let windowFrame = NSRect(
            x: visibleFrame.midX - windowWidth / 2,
            y: visibleFrame.midY - windowHeight / 2,
            width: windowWidth,
            height: windowHeight
        )
        let window = NSWindow(
            contentRect: windowFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let content = ContentView(store: store)
            .frame(minWidth: 980, minHeight: 680)

        let hostingController = NSHostingController(rootView: content)
        window.contentViewController = hostingController
        window.title = "Brain Builder"
        window.identifier = NSUserInterfaceItemIdentifier("BrainBuilderMainWindow")
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.managed, .fullScreenPrimary]
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        self.window = window
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            NSMenuItem(
                title: "Quit Brain Builder",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")

        let openItem = NSMenuItem(
            title: "Open Data Folder...",
            action: #selector(openFolderFromMenu),
            keyEquivalent: "o"
        )
        openItem.keyEquivalentModifierMask = [.command]
        openItem.target = self
        fileMenu.addItem(openItem)

        let rebuildItem = NSMenuItem(
            title: "Rebuild 3D Stack",
            action: #selector(rebuildVolumeFromMenu),
            keyEquivalent: "r"
        )
        rebuildItem.keyEquivalentModifierMask = [.command]
        rebuildItem.target = self
        fileMenu.addItem(rebuildItem)

        let exportItem = NSMenuItem(
            title: "Export Allen CCF Registration...",
            action: #selector(exportVolumeFromMenu),
            keyEquivalent: "e"
        )
        exportItem.keyEquivalentModifierMask = [.command, .shift]
        exportItem.target = self
        fileMenu.addItem(exportItem)

        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private static func runHeadlessCommandIfNeeded() -> Bool {
        let arguments = CommandLine.arguments
        if let prepareIndex = arguments.firstIndex(of: "--registration-prepare") {
            runRegistrationPrepare(arguments: arguments, commandIndex: prepareIndex)
            return true
        }
        if let poseIndex = arguments.firstIndex(of: "--registration-estimate-pose") {
            runRegistrationEstimatePose(arguments: arguments, commandIndex: poseIndex)
            return true
        }
        if let registerIndex = arguments.firstIndex(of: "--registration-register-slice") {
            runRegistrationRegisterSlice(arguments: arguments, commandIndex: registerIndex)
            return true
        }
        if let exportIndex = arguments.firstIndex(of: "--registration-export-atlas") {
            runRegistrationExportAtlas(arguments: arguments, commandIndex: exportIndex)
            return true
        }
        if let doctorIndex = arguments.firstIndex(of: "--registration-doctor") {
            runRegistrationDoctor(arguments: arguments, commandIndex: doctorIndex)
            return true
        }

        guard let scanIndex = arguments.firstIndex(of: "--headless-scan") else {
            if let exportIndex = arguments.firstIndex(of: "--export-obj") {
                runHeadlessExport(arguments: arguments, exportIndex: exportIndex)
                return true
            }
            if let atlasIndex = arguments.firstIndex(of: "--download-atlas") {
                runHeadlessAtlasDownload(arguments: arguments, atlasIndex: atlasIndex)
                return true
            }
            return false
        }

        let folderPath: String
        if arguments.indices.contains(scanIndex + 1) {
            folderPath = arguments[scanIndex + 1]
        } else {
            folderPath = "data"
        }

        let folderURL = URL(fileURLWithPath: folderPath)
        do {
            let dataset = try DatasetScanner().scan(rootURL: folderURL)
            let volume = try BrainVolumeBuilder(maxTexturePixels: 900).build(dataset: dataset, mode: .montageSections)

            print("BrainBuilder headless scan")
            print("root=\(dataset.rootURL.path)")
            print("groups=\(dataset.groups.count)")
            print("numberedSlices=\(dataset.totalSlices)")
            print("montageOverlays=\(dataset.montageCount)")
            print("volumeSlices=\(volume.slices.count)")
            print("sourceImages=\(volume.buildSummary.sourceImages)")
            print("rejectedComponents=\(volume.buildSummary.rejectedComponents)")
            print("atlas=\(volume.atlasRegistration.atlasName)")
            print("registrationMethod=\(volume.atlasRegistration.method)")
            print("priorConfidence=\(String(format: "%.3f", volume.atlasRegistration.meanConfidence))")
            print("morphologyContourScore=\(String(format: "%.3f", volume.atlasRegistration.meanContourScore))")
            print("foregroundQC=\(String(format: "%.3f", volume.buildSummary.meanForegroundConfidence))")
            print("backgroundRemoved=\(String(format: "%.3f", volume.buildSummary.meanBackgroundRemoved))")
            print("cortexMethod=\(volume.cortexRegistration.method)")
            print("cortexGeometryQC=\(String(format: "%.3f", volume.cortexRegistration.meanConfidence))")
            print("cortexMaskSymmetry=\(String(format: "%.3f", volume.cortexRegistration.meanSymmetry))")
            printAtlasQC(volume)

            for group in dataset.groups {
                let metadata = group.metadata
                let channels = metadata.capturedChannels.map(\.name).joined(separator: ",")
                let size = metadata.originalImageSize?.description ?? "unknown"
                let lens = metadata.lensName
                print("group=\(group.id) lens=\(lens) size=\(size) channels=\(channels)")
            }
            return true
        } catch {
            fputs("BrainBuilder headless scan failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func runRegistrationPrepare(arguments: [String], commandIndex: Int) {
        let folderPath = arguments.indices.contains(commandIndex + 1) ? arguments[commandIndex + 1] : "data"
        let outputPath = arguments.indices.contains(commandIndex + 2) ? arguments[commandIndex + 2] : "exports/registration-worker"

        do {
            let dataset = try DatasetScanner().scan(rootURL: URL(fileURLWithPath: folderPath))
            let volume = try BrainVolumeBuilder().build(dataset: dataset, mode: .montageSections)
            let worker = RegistrationWorkerService()
            let project = worker.makeProject(dataset: dataset, volume: volume)
            let result = try worker.prepare(
                project: project,
                volume: volume,
                outputURL: URL(fileURLWithPath: outputPath, isDirectory: true)
            )
            printWorkerResult(result)
        } catch {
            fputs("BrainBuilder registration prepare failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func runRegistrationEstimatePose(arguments: [String], commandIndex: Int) {
        guard arguments.indices.contains(commandIndex + 2) else {
            fputs("usage: BrainBuilder --registration-estimate-pose <project.json> <output-dir>\n", stderr)
            exit(2)
        }

        do {
            let worker = RegistrationWorkerService()
            let project = try worker.readProject(at: URL(fileURLWithPath: arguments[commandIndex + 1]))
            let result = try worker.estimatePose(
                project: project,
                outputURL: URL(fileURLWithPath: arguments[commandIndex + 2], isDirectory: true)
            )
            printWorkerResult(result)
        } catch {
            fputs("BrainBuilder registration pose failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func runRegistrationRegisterSlice(arguments: [String], commandIndex: Int) {
        guard arguments.indices.contains(commandIndex + 4) else {
            fputs("usage: BrainBuilder --registration-register-slice <project.json> <slice-id> <affine|spline> <output-dir>\n", stderr)
            exit(2)
        }
        guard let stage = RegistrationStage(rawValue: arguments[commandIndex + 3]),
              stage == .affine || stage == .spline else {
            fputs("registration stage must be affine or spline\n", stderr)
            exit(2)
        }

        do {
            let worker = RegistrationWorkerService()
            let project = try worker.readProject(at: URL(fileURLWithPath: arguments[commandIndex + 1]))
            let result = try worker.registerSlice(
                project: project,
                sliceID: arguments[commandIndex + 2],
                stage: stage,
                outputURL: URL(fileURLWithPath: arguments[commandIndex + 4], isDirectory: true)
            )
            printWorkerResult(result)
        } catch {
            fputs("BrainBuilder registration slice failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func runRegistrationExportAtlas(arguments: [String], commandIndex: Int) {
        guard arguments.indices.contains(commandIndex + 2) else {
            fputs("usage: BrainBuilder --registration-export-atlas <project.json> <output-dir>\n", stderr)
            exit(2)
        }

        do {
            let worker = RegistrationWorkerService()
            let project = try worker.readProject(at: URL(fileURLWithPath: arguments[commandIndex + 1]))
            let result = try worker.exportAtlas(
                project: project,
                outputURL: URL(fileURLWithPath: arguments[commandIndex + 2], isDirectory: true)
            )
            printWorkerResult(result)
        } catch RegistrationWorkerError.exportBlocked(let blockers) {
            print("BrainBuilder registration worker")
            print("command=\(RegistrationWorkerCommand.exportAtlas.rawValue)")
            print("stage=\(WorkerStage.blocked.rawValue)")
            for blocker in blockers {
                print("blocker=\(blocker)")
            }
            exit(2)
        } catch {
            fputs("BrainBuilder atlas export failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func runRegistrationDoctor(arguments: [String], commandIndex: Int) {
        let outputPath = arguments.indices.contains(commandIndex + 1)
            ? arguments[commandIndex + 1]
            : "exports/registration-worker-doctor"

        do {
            let result = try RegistrationWorkerService().doctor(
                outputURL: URL(fileURLWithPath: outputPath, isDirectory: true)
            )
            printWorkerResult(result)
        } catch {
            fputs("BrainBuilder registration doctor failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func printWorkerResult(_ result: RegistrationWorkerResult) {
        print("BrainBuilder registration worker")
        print("command=\(result.command)")
        print("stage=\(result.stage.rawValue)")
        if let projectID = result.projectID {
            print("projectID=\(projectID)")
        }
        if let outputPath = result.outputPath {
            print("output=\(outputPath)")
        }
        if let project = result.project {
            print("slices=\(project.slices.count)")
            print("atlas=\(project.atlas.id) \(project.atlas.version)")
            for blocker in project.blockersForAtlasExport {
                print("blocker=\(blocker)")
            }
        }
        if let slice = result.slice {
            print("sliceID=\(slice.id)")
            print("sliceStatus=\(slice.status.rawValue)")
            for warning in slice.qc.warnings {
                print("warning=\(warning)")
            }
        }
        if let export = result.export {
            print("sliceExports=\(export.sliceExports.count)")
        }
        for message in result.messages {
            print("message=\(message)")
        }
        switch result.stage {
        case .ok:
            break
        case .blocked:
            exit(2)
        case .failed:
            exit(1)
        }
    }

    private static func runHeadlessExport(arguments: [String], exportIndex: Int) {
        let folderPath = arguments.indices.contains(exportIndex + 1) ? arguments[exportIndex + 1] : "data"
        let outputPath = arguments.indices.contains(exportIndex + 2) ? arguments[exportIndex + 2] : "exports/last-reconstruction"

        do {
            let dataset = try DatasetScanner().scan(rootURL: URL(fileURLWithPath: folderPath))
            let volume = try BrainVolumeBuilder(maxTexturePixels: 900).build(dataset: dataset, mode: .montageSections)
            let result = try VolumeExportService().export(
                volume: volume,
                dataset: dataset,
                to: URL(fileURLWithPath: outputPath)
            )

            print("BrainBuilder OBJ export")
            print("folder=\(result.folderURL.path)")
            print("obj=\(result.objURL.path)")
            print("mtl=\(result.mtlURL.path)")
            print("metadata=\(result.metadataURL.path)")
            print("textures=\(result.textureCount)")
            print("actualSlices=\(result.actualSliceCount)")
            print("masks=\(result.maskCount)")
            print("volumeSlices=\(volume.slices.count)")
            print("atlas=\(volume.atlasRegistration.atlasName)")
            print("registrationMethod=\(volume.atlasRegistration.method)")
            print("priorConfidence=\(String(format: "%.3f", volume.atlasRegistration.meanConfidence))")
            print("morphologyContourScore=\(String(format: "%.3f", volume.atlasRegistration.meanContourScore))")
            print("foregroundQC=\(String(format: "%.3f", volume.buildSummary.meanForegroundConfidence))")
            print("cortexMethod=\(volume.cortexRegistration.method)")
            print("cortexGeometryQC=\(String(format: "%.3f", volume.cortexRegistration.meanConfidence))")
            printAtlasQC(volume)
        } catch {
            fputs("BrainBuilder OBJ export failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func printAtlasQC(_ volume: BrainVolume) {
        let report = volume.reliabilityReport
        // Keep the legacy machine-readable key names for CLI compatibility;
        // the meaning field makes their pre-registration scope explicit.
        print("atlasQCLevel=\(report.level.rawValue)")
        print("atlasQCScore=\(String(format: "%.3f", report.score))")
        print("atlasQCMeaning=stack-prior QC only; not measured Allen atlas alignment accuracy")
        print("allenReference=\(report.atlasReference.summary)")
        if let folder = report.atlasReference.folderURL {
            print("allenReferenceFolder=\(folder.path)")
        }
        for issue in report.issues.prefix(8) {
            print("atlasQCIssue=\(issue.severity.rawValue): \(issue.title) - \(issue.detail)")
        }
    }

    private static func runHeadlessAtlasDownload(arguments: [String], atlasIndex: Int) {
        let outputPath = arguments.indices.contains(atlasIndex + 1) ? arguments[atlasIndex + 1] : "exports/atlas-worker-doctor"
        let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true)

        do {
            let result = try RegistrationWorkerService().doctor(outputURL: outputURL)
            print("BrainBuilder BrainGlobe Allen CCF download")
            print("folder=\(AllenAtlasCatalog.atlasInstallationURL.path)")
            // Use the common stage handler so blocked and failed worker envelopes
            // cannot accidentally turn into a successful shell exit status.
            printWorkerResult(result)
        } catch {
            fputs("BrainBuilder Allen CCF download failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
