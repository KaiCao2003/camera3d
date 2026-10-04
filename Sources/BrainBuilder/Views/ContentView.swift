import SwiftUI

struct ContentView: View {
    @ObservedObject var store: BrainProjectStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    @State private var workspaceViewMode: WorkspaceViewMode = .register
    @State private var showMetadataInspector = false
    @State private var showRegistrationInspector = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(store: store)
        } detail: {
            BrainWorkspaceView(store: store, workspaceViewMode: workspaceViewMode)
                .inspector(isPresented: workspaceInspectorBinding) {
                    workspaceInspector
                        .inspectorColumnWidth(min: 280, ideal: 340, max: 420)
                }
        }
        .navigationSplitViewStyle(.balanced)
        .preferredColorScheme(.light)
        .onChange(of: workspaceViewMode) {
            columnVisibility = workspaceViewMode.showsDatasetSidebar ? .all : .detailOnly
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    store.openFolderPanel()
                } label: {
                    Label("Open", systemImage: "folder")
                }
                .disabled(store.isBusy)
                .help("Open microscope data folder")

                Picker(
                    "Stack source",
                    selection: Binding(
                        get: { store.sourceMode },
                        set: { store.changeSourceMode(to: $0) }
                    )
                ) {
                    ForEach(StackSourceMode.allCases) { mode in
                        Text(mode.shortTitle).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
                .disabled(store.isBusy)
                .help("Choose whether the 3D stack is built from detected montage sections or numbered overlay tiles")

                Picker("Workspace", selection: $workspaceViewMode) {
                    ForEach(WorkspaceViewMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 250)

                Button {
                    Task { await store.rebuildVolume() }
                } label: {
                    Label("Rebuild", systemImage: "cube.transparent")
                }
                .disabled(store.dataset == nil || store.isBusy)
                .help("Rebuild the 3D slice stack")

                Button {
                    store.exportAtlasWithPanel()
                } label: {
                    Label("Export Atlas", systemImage: "square.and.arrow.up")
                }
                .disabled(!store.canExportAtlas)
                .help("Export accepted Allen CCF atlas transforms and region artifacts")

                if workspaceViewMode.showsMetadataInspector || workspaceViewMode == .register {
                    Button {
                        toggleWorkspaceInspector()
                    } label: {
                        Label("Inspector", systemImage: "sidebar.right")
                    }
                    .help(
                        workspaceViewMode == .register
                            ? "Toggle registration review inspector"
                            : "Toggle metadata inspector"
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var workspaceInspector: some View {
        if workspaceViewMode == .register {
            AtlasRegistrationInspectorPanel(store: store)
        } else {
            MetadataInspectorView(store: store)
        }
    }

    private var workspaceInspectorBinding: Binding<Bool> {
        Binding(
            get: {
                switch workspaceViewMode {
                case .reconstruct, .split:
                    showMetadataInspector
                case .register:
                    showRegistrationInspector
                case .export:
                    false
                }
            },
            set: { newValue in
                switch workspaceViewMode {
                case .reconstruct, .split:
                    showMetadataInspector = newValue
                case .register:
                    showRegistrationInspector = newValue
                case .export:
                    break
                }
            }
        )
    }

    private func toggleWorkspaceInspector() {
        if workspaceViewMode == .register {
            showRegistrationInspector.toggle()
        } else {
            showMetadataInspector.toggle()
        }
    }
}

private struct BrainWorkspaceView: View {
    @ObservedObject var store: BrainProjectStore
    var workspaceViewMode: WorkspaceViewMode

    var body: some View {
        VStack(spacing: 0) {
            if store.dataset == nil {
                EmptyDatasetView(store: store)
            } else {
                if workspaceViewMode != .register {
                    WorkflowHeaderView(store: store)
                        .background(BrainBuilderTheme.canvas)
                }

                switch workspaceViewMode {
                case .reconstruct:
                    ReconstructionPane(store: store)
                case .split:
                    SplitDiagnosticsPane(store: store)
                case .register:
                    AtlasRegistrationWorkbenchView(store: store)
                case .export:
                    ExportPane(store: store)
                }
            }

            WorkspaceStatusBar(store: store)
        }
        .background(BrainBuilderTheme.canvas)
    }
}

private struct ReconstructionPane: View {
    @ObservedObject var store: BrainProjectStore
    @State private var cameraRequest = BrainCameraRequest()
    @State private var retrospectiveVisibility = Brain3DRetrospectiveOverlayVisibility()

    var body: some View {
        let retrospectiveSnapshot = Brain3DRetrospectiveOverlaySnapshot.locked(
            context: store.registrationProject?.brain3dContext
        )
        VStack(spacing: 0) {
            if store.volume == nil && store.isBuildingVolume {
                BuildInProgressView(status: store.status)
            } else if store.sourceMode == .montageSections,
                      !store.sectionOrientationState.permitsSectionRasterPresentation {
                SectionOrientationGateView(store: store)
            } else if store.volume == nil {
                NoVolumeView(status: store.status) {
                    Task { await store.rebuildVolume() }
                }
            } else {
                ZStack(alignment: .bottomLeading) {
                    BrainStackSceneView(
                        volume: store.volume,
                        selectedSliceID: store.selectedVolumeSlice?.id,
                        cameraRequest: cameraRequest,
                        atlas: store.atlas,
                        retrospectiveSnapshot: retrospectiveSnapshot,
                        retrospectiveVisibility: retrospectiveVisibility
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(BrainBuilderTheme.border, lineWidth: 1)
                        }

                    ReconstructionStatusCard(
                        title: store.volume?.sourceMode.title ?? "No 3D stack",
                        status: store.status,
                        report: store.volume?.reliabilityReport,
                        quantitativePlacementCount: store.volume?.slices.filter { $0.atlasPlacement != nil }.count ?? 0,
                        reviewedPlacementCount: store.volume?.slices.filter { $0.atlasPlacement?.isReviewed == true }.count ?? 0,
                        sliceCount: store.volume?.slices.count ?? 0,
                        referenceMeshState: store.atlas.referenceMeshState,
                        reliabilityImage: reliabilityImage,
                        reliabilityColor: reliabilityColor
                    )
                    .padding(18)

                    VStack {
                        HStack {
                            Spacer()
                            VStack(alignment: .trailing, spacing: 8) {
                                CameraPresetBar(cameraRequest: $cameraRequest)
                                if let retrospectiveSnapshot {
                                    Brain3DRetrospectiveOverlayToggleBar(
                                        visibility: $retrospectiveVisibility,
                                        snapshot: retrospectiveSnapshot
                                    )
                                }
                            }
                        }
                        Spacer()
                    }
                    .padding(18)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }

            if store.volume?.slices.isEmpty == false {
                SliceStripView(store: store)
                    .frame(height: 132)
                    .background(BrainBuilderTheme.sidebar)
            }
        }
        .background(BrainBuilderTheme.canvas)
    }

    private func reliabilityImage(for level: ReliabilityLevel) -> String {
        switch level {
        case .atlasValidated:
            "checkmark.seal.fill"
        case .needsAtlasRegistration:
            "scope"
        case .review:
            "exclamationmark.triangle.fill"
        case .unreliable:
            "xmark.octagon.fill"
        }
    }

    private func reliabilityColor(for level: ReliabilityLevel) -> Color {
        switch level {
        case .atlasValidated:
            .green
        case .needsAtlasRegistration:
            .blue
        case .review:
            .orange
        case .unreliable:
            .red
        }
    }
}

private struct SectionOrientationGateView: View {
    @ObservedObject var store: BrainProjectStore

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: stateImage)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.white.opacity(0.72))

            VStack(spacing: 5) {
                Text(stateTitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                Text(store.sectionOrientationState.detail)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.74))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }

            if store.sectionOrientationState == .estimating {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Estimating canonical section orientation")
            } else if store.canRetrySectionOrientation {
                Button {
                    store.retrySectionOrientation()
                } label: {
                    Label("Retry Orientation", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrainBuilderTheme.sceneBackgroundColor)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("section-orientation-state")
    }

    private var stateTitle: String {
        switch store.sectionOrientationState {
        case .pending:
            "Canonical orientation pending"
        case .estimating:
            "Estimating section orientation"
        case .unavailable:
            "Canonical orientation unavailable"
        case .notRequired:
            "Raw tile preview"
        case .ready:
            "Canonical orientation verified"
        }
    }

    private var stateImage: String {
        switch store.sectionOrientationState {
        case .unavailable:
            "exclamationmark.triangle"
        case .pending, .estimating:
            "square.stack.3d.down.right"
        case .notRequired:
            "square.grid.2x2"
        case .ready:
            "checkmark.seal"
        }
    }
}

private struct CameraPresetBar: View {
    @Binding var cameraRequest: BrainCameraRequest

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 5) {
                Text("R").foregroundStyle(.red)
                Text("D").foregroundStyle(.green)
                Text("P").foregroundStyle(.blue)
            }
            .font(.caption2.monospaced().weight(.bold))
            .padding(.horizontal, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Axes: red right, green dorsal, blue posterior")

            Divider()
                .frame(height: 18)

            ForEach(BrainCameraPreset.allCases) { preset in
                if cameraRequest.preset == preset {
                    cameraButton(for: preset)
                        .buttonStyle(.borderedProminent)
                } else {
                    cameraButton(for: preset)
                        .buttonStyle(.bordered)
                }
            }
        }
        .controlSize(.small)
        .padding(5)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("3D camera views")
    }

    private func cameraButton(for preset: BrainCameraPreset) -> some View {
        Button {
            cameraRequest = BrainCameraRequest(preset: preset)
        } label: {
            Text(preset.title)
        }
        .help("Reset camera to the \(preset.title.lowercased()) view")
        .accessibilityLabel("\(preset.title) camera view")
    }
}

private struct ReconstructionStatusCard: View {
    var title: String
    var status: String
    var report: ReliabilityReport?
    var quantitativePlacementCount: Int
    var reviewedPlacementCount: Int
    var sliceCount: Int
    var referenceMeshState: AllenReferenceMeshLoadState
    var reliabilityImage: (ReliabilityLevel) -> String
    var reliabilityColor: (ReliabilityLevel) -> Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .font(.title3)
                .foregroundStyle(BrainBuilderTheme.secondaryText)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(BrainBuilderTheme.secondaryText)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if referenceMeshState.isLoading {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityHidden(true)
                    }
                    Text(geometrySummary)
                        .lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(BrainBuilderTheme.secondaryText)
            }

            if let report {
                Divider()
                    .frame(height: 32)
                Label(
                    "\(report.level.title)  \(report.score, specifier: "%.2f")",
                    systemImage: reliabilityImage(report.level)
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(reliabilityColor(report.level))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(title). \(status). \(referenceMeshState.conciseDescription). \(geometrySummary)"
        )
    }

    private var geometrySummary: String {
        let planes = quantitativePlacementCount > 0
            ? "\(quantitativePlacementCount)/\(sliceCount) affine previews · \(reviewedPlacementCount)/\(quantitativePlacementCount) accepted"
            : "no quantitative specimen planes"
        switch referenceMeshState {
        case .loading:
            return "Validating Allen CCF reference · \(planes)"
        case .loaded:
            return "Allen CCF reference · \(planes)"
        case .unavailable:
            return "Allen CCF reference unavailable · \(planes)"
        case .failed:
            return "Allen CCF reference failed validation · \(planes)"
        }
    }
}

private struct BuildInProgressView: View {
    var status: String

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Building 3D stack")
                .font(.title3)
            Text(status)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrainBuilderTheme.canvas)
    }
}

private struct NoVolumeView: View {
    var status: String
    var rebuild: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            Text("No 3D stack is available")
                .font(.title3)
            Text(status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button {
                rebuild()
            } label: {
                Label("Rebuild Stack", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrainBuilderTheme.canvas)
    }
}

private struct EmptyDatasetView: View {
    @ObservedObject var store: BrainProjectStore

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.secondary)
            Text("Open a microscope data folder")
                .font(.title2)
            Text("Brain Builder reads Keyence .gci metadata, finds TIFF channels, extracts tissue sections, and builds a 3D slice stack.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Button {
                store.openFolderPanel()
            } label: {
                Label("Open Folder", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isBusy)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrainBuilderTheme.canvas)
    }
}
