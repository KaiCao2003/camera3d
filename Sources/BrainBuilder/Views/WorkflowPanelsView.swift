import SwiftUI

enum WorkspaceStatusCategory: Equatable {
    case working
    case success
    case warning
    case failure
    case neutral

    init(message: String, isBusy: Bool) {
        if isBusy {
            self = .working
            return
        }

        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let failureMarkers = ["failed", "rejected", "error", "unavailable", "invalid", "mismatch"]
        if failureMarkers.contains(where: normalized.contains) {
            self = .failure
            return
        }

        let warningMarkers = ["blocked", "canceled", "wait for", "needs ", "requires ", "cannot "]
        if normalized.hasPrefix("no ") || warningMarkers.contains(where: normalized.contains) {
            self = .warning
            return
        }

        let successPrefixes = [
            "accepted ", "built ", "exported ", "loaded ", "locked ", "unlocked ",
            "restored ", "review complete", "set "
        ]
        if normalized == "ready"
            || normalized.contains(" is ready")
            || successPrefixes.contains(where: normalized.hasPrefix) {
            self = .success
            return
        }

        self = .neutral
    }

    var systemImage: String {
        switch self {
        case .working:
            "arrow.trianglehead.2.clockwise.rotate.90"
        case .success:
            "checkmark.circle.fill"
        case .warning:
            "exclamationmark.triangle.fill"
        case .failure:
            "xmark.octagon.fill"
        case .neutral:
            "info.circle"
        }
    }

    var color: Color {
        switch self {
        case .working:
            BrainBuilderTheme.accent
        case .success:
            BrainBuilderTheme.mint
        case .warning:
            BrainBuilderTheme.amber
        case .failure:
            BrainBuilderTheme.rose
        case .neutral:
            BrainBuilderTheme.secondaryText
        }
    }
}

struct WorkflowHeaderView: View {
    @ObservedObject var store: BrainProjectStore

    var body: some View {
        HStack(spacing: 18) {
            MetricTile(
                title: "Acquisitions",
                value: "\(store.dataset?.groups.count ?? 0)",
                detail: "XY groups",
                systemImage: "square.grid.2x2.fill"
            )
            MetricTile(
                title: "Sections",
                value: "\(store.reviewedSliceCount)",
                detail: store.excludedSliceIDs.isEmpty ? "reviewed stack" : "\(store.excludedSliceIDs.count) excluded",
                systemImage: "rectangle.stack.fill"
            )
            MetricTile(
                title: "Segmentation",
                value: store.volume.map { String(format: "%.2f", $0.buildSummary.meanForegroundConfidence) } ?? "--",
                detail: "foreground QC",
                systemImage: "wand.and.stars"
            )
            MetricTile(
                title: "Cortex",
                value: store.volume.map { String(format: "%.2f", $0.cortexRegistration.meanConfidence) } ?? "--",
                detail: "geometry QC",
                systemImage: "brain.head.profile.fill"
            )
            MetricTile(
                title: "AP prior · µm",
                value: store.volume.map { String(format: "%.0f–%.0f", $0.atlasRegistration.apRangeMicrons.lowerBound, $0.atlasRegistration.apRangeMicrons.upperBound) } ?? "--",
                detail: store.volume.map { "pre-reg QC " + String(format: "%.2f", $0.reliabilityReport.score) } ?? "not registered",
                systemImage: "scope"
            )
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

struct WorkspaceStatusBar: View {
    @ObservedObject var store: BrainProjectStore

    private var category: WorkspaceStatusCategory {
        WorkspaceStatusCategory(message: store.status, isBusy: store.isBusy)
    }

    var body: some View {
        HStack(spacing: 8) {
            if store.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .tint(category.color)
                    .accessibilityLabel("Operation in progress")
            } else {
                Image(systemName: category.systemImage)
                    .foregroundStyle(category.color)
                    .accessibilityHidden(true)
            }

            Text(store.status)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(store.status)

            Spacer(minLength: 12)

            if store.canUndoWorkspaceAction {
                Button {
                    store.undoLastWorkspaceAction()
                } label: {
                    Label(store.workspaceUndoButtonTitle, systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .keyboardShortcut("z", modifiers: .command)
                .help(store.workspaceUndoHelp)
            }

            if store.isRunningRegistrationWorker {
                Button {
                    store.cancelRegistrationWorker()
                } label: {
                    Label(
                        store.isCancelingRegistrationWorker ? "Canceling" : "Cancel",
                        systemImage: "xmark.circle"
                    )
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(store.isCancelingRegistrationWorker)
                .keyboardShortcut(.cancelAction)
                .help("Stop the current registration worker")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(minHeight: 30)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(BrainBuilderTheme.border)
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }

}

private struct MetricTile: View {
    var title: String
    var value: String
    var detail: String
    var systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(BrainBuilderTheme.secondaryText)
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption)
                    .foregroundStyle(BrainBuilderTheme.secondaryText)
                Text(value)
                    .font(.headline)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Text(detail)
                .font(.caption2)
                .foregroundStyle(BrainBuilderTheme.secondaryText)
                .lineLimit(1)
        }
        .frame(minWidth: 112, alignment: .leading)
    }
}

struct SplitDiagnosticsPane: View {
    @ObservedObject var store: BrainProjectStore

    private let columns = [
        GridItem(.adaptive(minimum: 190, maximum: 250), spacing: 12)
    ]

    var body: some View {
        Group {
            if store.sourceMode == .montageSections,
               !store.sectionOrientationState.permitsSectionRasterPresentation {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.stack.badge.clock")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(BrainBuilderTheme.secondaryText)
                    Text("Section orientation pending")
                        .font(.title3.weight(.semibold))
                    Text("Raw detection rasters are withheld until DeepSlice orientation is verified.")
                        .font(.callout)
                        .foregroundStyle(BrainBuilderTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("split-orientation-state")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        SplitReviewHeader(store: store)

                        if let selected = store.selectedVolumeSlice {
                            SelectedSplitSectionCard(
                                slice: selected,
                                canExclude: store.canExcludeVolumeSlice,
                                exclude: {
                                    store.excludeVolumeSlice(id: selected.id)
                                }
                            )
                        }

                        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                            ForEach(store.volume?.slices ?? []) { slice in
                                SplitTile(
                                    slice: slice,
                                    isSelected: store.selectedSliceID == slice.id,
                                    canExclude: store.canExcludeVolumeSlice,
                                    select: {
                                        store.selectVolumeSlice(id: slice.id)
                                    },
                                    exclude: {
                                        store.excludeVolumeSlice(id: slice.id)
                                    }
                                )
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
    }
}

private struct SplitReviewHeader: View {
    @ObservedObject var store: BrainProjectStore

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Review detected sections")
                    .font(.headline)
                Text("\(store.reviewedSliceCount) kept from \(store.detectedSliceCount) detected sections")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            SectionNavigationControls(
                selectedIndex: store.selectedVolumeSliceIndex,
                totalCount: store.reviewedSliceCount,
                moveSelection: store.moveSelectedVolumeSlice
            )

            Button(role: .destructive) {
                if let slice = store.selectedVolumeSlice {
                    store.excludeVolumeSlice(id: slice.id)
                }
            } label: {
                Label("Exclude Selected", systemImage: "minus.circle")
            }
            .disabled(store.selectedVolumeSlice == nil || !store.canExcludeVolumeSlice)
            .help("Remove the selected detection from the reviewed stack")

            if store.excludedSliceIDs.isEmpty == false {
                Button {
                    store.restoreExcludedVolumeSlices()
                } label: {
                    Label("Restore \(store.excludedSliceIDs.count)", systemImage: "arrow.uturn.backward")
                }
                .disabled(!store.canRestoreExcludedVolumeSlices)
                .help("Restore all sections removed during this review")
            }
        }
    }
}

private struct SelectedSplitSectionCard: View {
    var slice: VolumeSlice
    var canExclude: Bool
    var exclude: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: slice.texture)
                .resizable()
                .scaledToFit()
                .frame(width: 250, height: 168)
                .background(Color.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 6))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(slice.title)
                        .font(.headline)
                        .lineLimit(1)
                    SplitQualityBadge(signal: slice.signal)
                    Spacer()
                }

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 7) {
                    GridRow {
                        SplitDetailLabel("Foreground")
                        Text("\(slice.signal.foregroundConfidence, specifier: "%.2f")")
                            .monospacedDigit()
                    }
                    GridRow {
                        SplitDetailLabel("Fill")
                        Text("\(slice.signal.componentFillRatio, specifier: "%.2f")")
                            .monospacedDigit()
                    }
                    GridRow {
                        SplitDetailLabel("Component")
                        Text(componentBoundsText(slice.signal.componentBounds))
                            .monospacedDigit()
                    }
                    GridRow {
                        SplitDetailLabel("Edge")
                        Text(slice.signal.touchesLateralCropEdge ? "Side edge" : "Clear")
                    }
                }
                .font(.caption)

                if slice.signal.sectionReviewFlags.isEmpty == false {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(slice.signal.sectionReviewFlags, id: \.self) { flag in
                            Label(flag, systemImage: "exclamationmark.triangle")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Spacer(minLength: 0)

                Button(role: .destructive, action: exclude) {
                    Label("Exclude Section", systemImage: "minus.circle")
                }
                .buttonStyle(.bordered)
                .disabled(!canExclude)
                .help("Remove this detection from the reviewed stack")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrainBuilderTheme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(BrainBuilderTheme.border, lineWidth: 1)
        }
    }
}

private struct SplitTile: View {
    var slice: VolumeSlice
    var isSelected: Bool
    var canExclude: Bool
    var select: () -> Void
    var exclude: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: select) {
                VStack(alignment: .leading, spacing: 8) {
                    ZStack(alignment: .topLeading) {
                        Image(nsImage: slice.texture)
                            .resizable()
                            .scaledToFill()
                            .frame(height: 112)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(
                                        isSelected ? Color.accentColor : Color.secondary.opacity(0.22),
                                        lineWidth: isSelected ? 2 : 1
                                    )
                            }

                        SplitQualityBadge(signal: slice.signal)
                            .padding(6)
                    }

                    Text(slice.title)
                        .font(.callout)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(slice.title)
            .accessibilityValue(accessibilitySummary)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .help("Select \(slice.title)")

            HStack(spacing: 8) {
                SplitQualityText(signal: slice.signal)

                Spacer(minLength: 4)

                Button {
                    exclude()
                } label: {
                    Label("Exclude", systemImage: "minus.circle")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.red)
                .disabled(!canExclude)
                .help("Exclude this detection from the reviewed stack")
            }

            HStack {
                Text("fg \(slice.signal.foregroundConfidence, specifier: "%.2f")")
                Spacer()
                Text("bg \(slice.signal.backgroundSuppression * 100, specifier: "%.0f")%")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            ProgressView(value: slice.signal.foregroundConfidence)
                .progressViewStyle(.linear)
        }
        .padding(8)
        .background(
            isSelected ? BrainBuilderTheme.surfaceRaised : BrainBuilderTheme.surface,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(
                    isSelected ? BrainBuilderTheme.accent : BrainBuilderTheme.border,
                    lineWidth: isSelected ? 2 : 1
                )
        }
    }

    private var accessibilitySummary: String {
        let review = slice.signal.sectionReviewFlags.isEmpty
            ? "Quality OK"
            : "Review: \(slice.signal.sectionReviewFlags.joined(separator: ", "))"
        let selection = isSelected ? "Selected. " : ""
        return "\(selection)\(review). Foreground \(slice.signal.foregroundConfidence.formatted(.number.precision(.fractionLength(2))))"
    }
}

private struct SplitQualityText: View {
    var signal: SliceSignal

    var body: some View {
        if signal.sectionReviewFlags.isEmpty {
            Label("OK", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
                .lineLimit(1)
        } else {
            Label(signal.sectionReviewFlags.joined(separator: ", "), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
                .lineLimit(1)
        }
    }
}

private struct SplitQualityBadge: View {
    var signal: SliceSignal

    var body: some View {
        if signal.sectionReviewFlags.isEmpty {
            Label("OK", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption2)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .foregroundStyle(.green)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            Label(signal.sectionReviewFlags.joined(separator: ", "), systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption2)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .foregroundStyle(.orange)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }
}

private struct SplitDetailLabel: View {
    var title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .foregroundStyle(.secondary)
    }
}

private func componentBoundsText(_ rect: CGRect) -> String {
    String(format: "%.0f x %.0f", rect.width, rect.height)
}

struct RegistrationDiagnosticsPane: View {
    @ObservedObject var store: BrainProjectStore

    var body: some View {
        ScrollView {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 9) {
                GridRow {
                    HeaderText("Slice")
                    HeaderText("AP prior um")
                    HeaderText("Prior scale")
                    HeaderText("Cortex geom.")
                    HeaderText("Symmetry")
                    HeaderText("Split")
                }

                Divider()
                    .gridCellColumns(6)

                ForEach(store.volume?.slices ?? []) { slice in
                    GridRow {
                        Text(slice.title)
                            .lineLimit(1)
                        Text("\(slice.registration.atlasAPMicrons, specifier: "%.0f")")
                            .monospacedDigit()
                        Text("\(slice.registration.atlasScale, specifier: "%.2f")")
                            .monospacedDigit()
                        Text("\(slice.cortex.confidence, specifier: "%.2f")")
                            .monospacedDigit()
                        Text("\(slice.cortex.symmetryScore, specifier: "%.2f")")
                            .monospacedDigit()
                        Text("\(slice.signal.foregroundConfidence, specifier: "%.2f")")
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(store.selectedSliceID == slice.id ? .primary : .secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct HeaderText: View {
    var value: String

    init(_ value: String) {
        self.value = value
    }

    var body: some View {
        Text(value)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

struct ExportPane: View {
    @ObservedObject var store: BrainProjectStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                exportActions

                if let project = store.registrationProject {
                    atlasReadinessCard(project)
                    channelRolesCard(project)
                } else {
                    ExportSectionCard(title: "Atlas export readiness") {
                        Label("Load a dataset and build a stack before exporting atlas registration artifacts.", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                }

                if let result = store.lastWorkerResult {
                    workerResultCard(result)
                }

                if let result = store.lastExportResult {
                    objResultCard(result)
                }

                if let volume = store.volume {
                    volumeSummaryCard(volume)
                }
            }
            .padding(20)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var exportActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                exportActionButtons
            }

            VStack(alignment: .leading, spacing: 10) {
                exportActionButtons
            }
        }
    }

    @ViewBuilder
    private var exportActionButtons: some View {
        Button {
            store.exportAtlasWithPanel()
        } label: {
            Label("Export Atlas Registration", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(.borderedProminent)
        .disabled(!store.canExportAtlas)
        .help("Export reviewed Allen CCF transforms and atlas artifacts when all blockers are cleared")

        Button {
            store.exportCurrentVolumeWithPanel()
        } label: {
            Label("Export OBJ Preview", systemImage: "cube.transparent")
        }
        .disabled(store.dataset == nil || store.volume == nil || store.isExporting || store.isBuildingVolume)
        .help("Export a visual OBJ preview of the current 3D stack")

        Button {
            Task { await store.atlas.downloadReferenceSet() }
        } label: {
            Label("Download Allen CCF", systemImage: "arrow.down.circle")
        }
        .disabled(store.atlas.isDownloading)
    }

    private func atlasReadinessCard(_ project: RegistrationProject) -> some View {
        let blockers = project.blockersForAtlasExport
        return ExportSectionCard(title: "Atlas export readiness") {
            if blockers.isEmpty {
                Label("Accepted transform chains are ready for atlas coordinate and region export.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(BrainBuilderTheme.mint)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Label(
                        "\(blockers.count) \(blockers.count == 1 ? "issue" : "issues") to resolve",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BrainBuilderTheme.amber)

                    Text("Finish these checks in Atlas before exporting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(blockers.indices, id: \.self) { index in
                        Label(blockers[index], systemImage: "circle")
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func channelRolesCard(_ project: RegistrationProject) -> some View {
        ExportSectionCard(title: "Registration channels") {
            Text("Mark an anatomical channel as Structural before trusting atlas registration.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ChannelRoleEditorView(store: store)
        }
    }

    private func workerResultCard(_ result: RegistrationWorkerResult) -> some View {
        ExportSectionCard(title: "Last atlas worker result") {
            ExportKeyValueLine("Command", result.command)
            ExportKeyValueLine("Stage", result.stage.rawValue)
            ExportKeyValueLine("Output", result.outputPath ?? "--", selectable: true)
            ForEach(result.messages.indices, id: \.self) { index in
                Text(result.messages[index])
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func objResultCard(_ result: VolumeExportResult) -> some View {
        ExportSectionCard(title: "Last OBJ preview export") {
            Label("OBJ preview output is visual evidence only, not atlas registration evidence.", systemImage: "info.circle")
                .foregroundStyle(.secondary)
            ExportKeyValueLine("OBJ", result.objURL.path, selectable: true)
            ExportKeyValueLine("Metadata", result.metadataURL.path, selectable: true)
            ExportKeyValueLine("Textures", "\(result.textureCount)")
            ExportKeyValueLine("Actual slices", "\(result.actualSliceCount)")
            ExportKeyValueLine("Masks", "\(result.maskCount)")
        }
    }

    private func volumeSummaryCard(_ volume: BrainVolume) -> some View {
        ExportSectionCard(title: "Current stack summary") {
            ExportKeyValueLine("Atlas target", volume.atlasRegistration.atlasName)
            ExportKeyValueLine("Cortex geometry", String(format: "%.2f", volume.cortexRegistration.meanConfidence))
            ExportKeyValueLine("Split", String(format: "%.2f", volume.buildSummary.meanForegroundConfidence))
            ExportKeyValueLine("Prior morphology", String(format: "%.2f", volume.atlasRegistration.meanContourScore))
            ExportKeyValueLine("Pre-reg QC", "\(volume.reliabilityReport.level.title) \(String(format: "%.2f", volume.reliabilityReport.score))")
            ExportKeyValueLine("Allen CCF", volume.reliabilityReport.atlasReference.summary)
        }
    }
}

private struct ExportSectionCard<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brainBuilderPanel(cornerRadius: 6, fill: BrainBuilderTheme.surface)
        .accessibilityElement(children: .contain)
    }
}

private struct ExportKeyValueLine: View {
    var key: String
    var value: String
    var selectable: Bool

    init(_ key: String, _ value: String, selectable: Bool = false) {
        self.key = key
        self.value = value
        self.selectable = selectable
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(key)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            if selectable {
                Text(value)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
            } else {
                Text(value)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
    }
}
