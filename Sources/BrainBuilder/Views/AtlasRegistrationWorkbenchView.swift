import SwiftUI

struct AtlasRegistrationWorkbenchView: View {
    @ObservedObject var store: BrainProjectStore
    @State private var overlayMode: ReviewOverlayMode = .opacity
    @State private var showsQueue = true
    @State private var retrospectiveVisibility = Brain3DRetrospectiveOverlayVisibility()

    var body: some View {
        let retrospectiveSnapshot = Brain3DRetrospectiveOverlaySnapshot.locked(
            context: store.registrationProject?.brain3dContext
        )
        HStack(spacing: 12) {
            if showsQueue {
                SliceRegistrationQueueView(store: store)
                    .frame(width: 210)
                    .brainBuilderPanel(fill: .white)
            }

            VStack(spacing: 0) {
                AtlasRegistrationToolbarView(
                    store: store,
                    showsQueue: $showsQueue,
                    overlayMode: $overlayMode,
                    retrospectiveVisibility: $retrospectiveVisibility,
                    retrospectiveSnapshot: retrospectiveSnapshot
                )

                AtlasReviewViewer(
                    slice: store.selectedRegistrationSlice,
                    volumeSlice: store.volumeSlice(forRegistrationSliceID: store.selectedRegistrationSlice?.id),
                    overlayMode: $overlayMode,
                    structuresPath: atlasStructuresPath,
                    orientationState: store.sectionOrientationState,
                    retrospectiveVisibility: retrospectiveVisibility,
                    retrospectiveSnapshot: retrospectiveSnapshot
                )
            }
            .brainBuilderPanel(fill: .white)
        }
        .padding(12)
        .background(.white)
        .environment(\.colorScheme, .light)
        .sheet(item: $store.abbaReviewPreview) { preview in
            ABBAReviewSheet(preview: preview)
        }
    }

    private var atlasStructuresPath: String {
        let atlasRoot = store.registrationProject?.atlasAssets?.atlasRootPath
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? AllenAtlasCatalog.atlasInstallationURL
        return atlasRoot.appendingPathComponent("structures.json").path
    }
}

private enum ReviewOverlayMode: String, CaseIterable, Identifiable {
    case histology
    case atlas
    case opacity
    case track
    case borders
    case checkerboard
    case difference

    var id: String { rawValue }

    var title: String {
        switch self {
        case .histology:
            "Histology"
        case .atlas:
            "Atlas"
        case .opacity:
            "Overlay"
        case .track:
            "Track"
        case .borders:
            "Borders"
        case .checkerboard:
            "Checker"
        case .difference:
            "Diff"
        }
    }

    var supportsDirectRegionLookup: Bool {
        self != .track
    }
}

private struct SliceRegistrationQueueView: View {
    @ObservedObject var store: BrainProjectStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.down.right")
                    .foregroundStyle(BrainBuilderTheme.secondaryText)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Registration queue")
                        .font(.headline)
                    Text(queueProgress)
                        .font(.caption2)
                        .foregroundStyle(BrainBuilderTheme.secondaryText)
                }
            }
            .padding(14)

            Divider().overlay(BrainBuilderTheme.border)

            List(selection: $store.selectedRegistrationSliceID) {
                Section {
                ForEach(store.registrationProject?.slices ?? []) { slice in
                    HStack(spacing: 10) {
                        Image(systemName: icon(for: slice.status))
                            .foregroundStyle(color(for: slice.status))
                            .frame(width: 16)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(slice.title)
                                .lineLimit(1)
                            Text(queueDetail(for: slice))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 3)
                    .tag(Optional(slice.id))
                }
                } header: {
                    BrainBuilderSectionLabel("Sections")
                }

                if let project = store.registrationProject {
                    Section {
                        Label("Allen CCF \(project.atlas.version)", systemImage: "map.fill")
                        Label(project.orientation.title, systemImage: "square.stack.3d.down.right.fill")
                        Label(
                            "\(project.reviewedSlices.count)/\(project.slices.count) reviewed",
                            systemImage: "checklist"
                        )
                    } header: {
                        BrainBuilderSectionLabel("Project")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.sidebar)
        }
    }

    private var queueProgress: String {
        guard let project = store.registrationProject else {
            return "No sections"
        }
        guard store.sectionOrientationState.permitsSectionRasterPresentation else {
            return "\(project.slices.count) sections · orientation pending"
        }
        return "\(project.reviewedSlices.count) of \(project.slices.count) reviewed · \(project.acceptedSlices.count) accepted"
    }

    private func queueDetail(for slice: SliceRegistrationRecord) -> String {
        guard store.sectionOrientationState.permitsSectionRasterPresentation else {
            return "Orientation pending"
        }
        let ap = slice.pose.map { String(format: "%.0f um", $0.atlasAPMicrons) } ?? "no AP"
        let rotation = slice.pose.map { "\(Int($0.rotationDegrees))°" } ?? "no orientation"
        return "\(slice.status.title), \(ap), \(rotation)"
    }

    private func icon(for status: SliceRegistrationStatus) -> String {
        switch status {
        case .unprepared:
            "circle.dashed"
        case .prepared:
            "circle"
        case .poseEstimated:
            "scope"
        case .affineDone:
            "arrow.up.left.and.down.right.magnifyingglass"
        case .splineDone:
            "point.3.connected.trianglepath.dotted"
        case .needsReview:
            "exclamationmark.circle.fill"
        case .accepted:
            "checkmark.circle.fill"
        case .failed:
            "xmark.octagon.fill"
        }
    }

    private func color(for status: SliceRegistrationStatus) -> Color {
        switch status {
        case .accepted:
            .green
        case .needsReview:
            .orange
        case .failed:
            .red
        case .affineDone, .splineDone, .poseEstimated:
            .blue
        case .unprepared, .prepared:
            .secondary
        }
    }
}

private struct AtlasRegistrationToolbarView: View {
    @ObservedObject var store: BrainProjectStore
    @Binding var showsQueue: Bool
    @Binding var overlayMode: ReviewOverlayMode
    @Binding var retrospectiveVisibility: Brain3DRetrospectiveOverlayVisibility
    var retrospectiveSnapshot: Brain3DRetrospectiveOverlaySnapshot?
    @State private var showsCompletionSummary = false
    @State private var showsCorrection = false

    var body: some View {
        let selectedSlice = store.selectedRegistrationSlice
        let project = store.registrationProject
        let isMontageProject = store.sourceMode == .montageSections && project?.sourceMode == .montageSections
        let canAccept = isMontageProject
            && selectedSlice?.status != .accepted
            && selectedSlice?.isReadyForAcceptance == true
        let canReject = selectedSlice != nil && selectedSlice?.status != .failed
        let canBulkAccept = isMontageProject && project?.slices.contains(where: {
            ($0.status == .affineDone || $0.status == .splineDone) && $0.isReadyForAcceptance
        }) == true
        let canEstimatePose = isMontageProject
            && project?.slices.isEmpty == false
            && project?.slices.allSatisfy(\.hasMaterializedRegistrationInput) == true
        let canRunAffine = isMontageProject
            && selectedSlice?.hasMaterializedRegistrationInput == true
            && selectedSlice?.hasWorkerEstimatedPose == true
        let poseIsLocked = selectedSlice?.pose?.manuallyLocked == true

        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    showsQueue.toggle()
                } label: {
                    Label("Sections", systemImage: "sidebar.left")
                }
                .labelStyle(.iconOnly)
                .help(showsQueue ? "Hide section queue" : "Show section queue")
                .accessibilityLabel(showsQueue ? "Hide section queue" : "Show section queue")

                Button {
                    store.autoRegisterAll()
                } label: {
                    Label("Auto Align (Affine)", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .tint(BrainBuilderTheme.accent)
                .disabled(project == nil || !isMontageProject || store.isBusy)
                .help("Materialize true section crops, match Allen AP planes, and run SimpleITK affine registration for every slice")

                Menu("Run") {
                    Button("Official ABBA · Affine + Spline") {
                        store.runOfficialABBA()
                    }
                    .disabled(
                        store.isBusy || !isMontageProject
                            || project?.slices.isEmpty != false
                            || project?.slices.allSatisfy(\.hasWorkerEstimatedPose) != true
                    )
                    .help("Refine all sections with the configured official ABBA runtime and open the result")

                    Divider()
                    Button {
                        store.prepareRegistrationProject()
                    } label: {
                        Label("Prepare", systemImage: "tray.and.arrow.down")
                    }
                    .disabled(project == nil || !isMontageProject || store.isBusy)
                    .help("Write the registration handoff project for external workers")

                    Button {
                        store.estimateRegistrationPose()
                    } label: {
                        Label("Pose", systemImage: "scope")
                    }
                    .disabled(!canEstimatePose || store.isBusy)
                    .help("Estimate atlas AP pose for all slices")

                    Button {
                        store.runSelectedSliceRegistration(stage: .affine)
                    } label: {
                        Label("Affine", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
                    }
                    .disabled(!canRunAffine || store.isBusy)
                    .help("Run affine registration for the selected slice")

                }
                .fixedSize()

                if let summary = store.completedAutoRegistrationSummary {
                    Button {
                        showsCompletionSummary.toggle()
                    } label: {
                        Label("Run report", systemImage: "chart.bar.doc.horizontal")
                    }
                    .popover(isPresented: $showsCompletionSummary) {
                        RegistrationCompletionSummaryView(summary: summary)
                            .frame(width: 360)
                            .padding(12)
                    }
                }

                Spacer(minLength: 0)
            }

            if store.completedAutoRegistrationSummary == nil,
               let progress = store.registrationProgress,
               store.isBusy {
                RegistrationWorkerProgressView(progress: progress)
            }

            ViewThatFits(in: .horizontal) {
                overlayPicker
                    .pickerStyle(.segmented)
                    .fixedSize(horizontal: true, vertical: false)
                overlayPicker
                    .pickerStyle(.menu)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let retrospectiveSnapshot {
                Brain3DRetrospectiveOverlayToggleBar(
                    visibility: $retrospectiveVisibility,
                    snapshot: retrospectiveSnapshot
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if project?.brain3dContext?.blindReviewLocked == true {
                Label(
                    "Build the post-lock match review to display retrospective layers",
                    systemImage: "eye.slash"
                )
                .font(.caption2)
                .foregroundStyle(BrainBuilderTheme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                if let slice = store.selectedRegistrationSlice {
                    Label(slice.title, systemImage: icon(for: slice.status))
                        .font(.caption)
                        .foregroundStyle(color(for: slice.status))
                        .lineLimit(1)

                    Text(slice.status.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Label("No slice selected", systemImage: "scope")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                RegistrationQueueNavigation(store: store)

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Button {
                    showsCorrection = true
                } label: {
                    Label("Correct…", systemImage: "move.3d")
                }
                .disabled(!store.canCorrectSelectedRegistrationSlice || store.isBusy)
                .sheet(isPresented: $showsCorrection) {
                    RegistrationCorrectionSheet(store: store)
                }

                Button {
                    store.rejectSelectedRegistrationSlice()
                } label: {
                    Label("Reject & Next", systemImage: "xmark")
                }
                .disabled(!canReject || store.isBusy)
                .help("Reject the selected section and move to the next section awaiting a decision (⌘⇧⌫)")
                .keyboardShortcut(.delete, modifiers: [.command, .shift])

                Button {
                    store.acceptSelectedRegistrationSlice()
                } label: {
                    Label("Accept & Next", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .tint(BrainBuilderTheme.accent)
                .disabled(!canAccept || store.isBusy)
                .help("Accept the selected section and move to the next section awaiting a decision (⌘↩)")
                .keyboardShortcut(.return, modifiers: .command)

                Menu {
                    Button("Undo correction") {
                        store.undoRegistrationCorrection()
                    }
                    .disabled(!store.canUndoRegistrationCorrection || store.isBusy)

                    Button {
                        store.rotateSelectedRegistrationSlice180()
                    } label: {
                        Label("Rotate 180°", systemImage: "rotate.right")
                    }
                    .disabled(store.selectedRegistrationSlice?.hasWorkerEstimatedPose != true || store.isBusy)

                    Button {
                        store.toggleSelectedPoseLock()
                    } label: {
                        Label(
                            poseIsLocked ? "Unlock Pose" : "Lock Pose",
                            systemImage: poseIsLocked ? "lock.fill" : "lock.open"
                        )
                    }
                    .disabled(store.selectedRegistrationSlice?.hasWorkerEstimatedPose != true || store.isBusy)

                    Button(role: .destructive) {
                        if let slice = store.selectedRegistrationSlice {
                            store.excludeVolumeSlice(id: slice.id)
                        }
                    } label: {
                        Label("Exclude Section", systemImage: "minus.circle")
                    }
                    .disabled(store.selectedRegistrationSlice == nil || !store.canExcludeVolumeSlice)

                    Button {
                        store.acceptAllRegisteredSlices()
                    } label: {
                        Label("Accept QC-Passing", systemImage: "checkmark.circle")
                    }
                    .disabled(!canBulkAccept || store.isBusy)

                    Divider()

                    Button("Export to ABBA…") {
                        store.exportABBABundleWithPanel()
                    }
                    .disabled(
                        store.isBusy
                            || project?.slices.isEmpty != false
                            || project?.slices.allSatisfy(\.hasWorkerEstimatedPose) != true
                    )

                    Button("Open ABBA Result…") {
                        store.openABBAResultWithPanel()
                    }
                    .disabled(store.isBusy)

                    Button {
                        store.exportAtlasWithPanel()
                    } label: {
                        Label("Export Atlas", systemImage: "square.and.arrow.up")
                    }
                    .disabled(!store.canExportAtlas)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("More review actions, bulk acceptance, and export")
            }
        }
        .padding(14)
    }

    private var overlayPicker: some View {
        Picker("View", selection: $overlayMode) {
            ForEach(ReviewOverlayMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .help("Compare registered histology, the atlas reference, or their overlay")
    }

    private func icon(for status: SliceRegistrationStatus) -> String {
        switch status {
        case .unprepared:
            "circle.dashed"
        case .prepared:
            "circle"
        case .poseEstimated:
            "scope"
        case .affineDone:
            "arrow.up.left.and.down.right.magnifyingglass"
        case .splineDone:
            "point.3.connected.trianglepath.dotted"
        case .needsReview:
            "exclamationmark.circle.fill"
        case .accepted:
            "checkmark.circle.fill"
        case .failed:
            "xmark.octagon.fill"
        }
    }

    private func color(for status: SliceRegistrationStatus) -> Color {
        switch status {
        case .accepted:
            .green
        case .needsReview:
            .orange
        case .failed:
            .red
        case .affineDone, .splineDone, .poseEstimated:
            .blue
        case .unprepared, .prepared:
            .secondary
        }
    }
}

private struct RegistrationWorkerProgressView: View {
    let progress: RegistrationWorkerProgress

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: progress.stage == .failed ? "exclamationmark.triangle.fill" : "waveform.path.ecg")
                .foregroundStyle(progress.stage == .failed ? Color.orange : BrainBuilderTheme.accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(progress.displayTitle)
                        .font(.caption.weight(.semibold))

                    Spacer(minLength: 8)

                    if showsSectionCount {
                        Text("\(progress.completed)/\(progress.total)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    if progress.failed > 0 {
                        Text("\(progress.failed) failed")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.orange)
                    }
                }

                if showsDeterminateProgress, let fraction = progress.fractionCompleted {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }

                Text(progress.message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(BrainBuilderTheme.border, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(progress.displayTitle)
        .accessibilityValue(accessibilityValue)
    }

    private var showsDeterminateProgress: Bool {
        switch progress.stage {
        case .registeringSlices, .finalizing, .completed:
            true
        case .preparing, .loadingAtlas, .estimatingPose, .failed:
            false
        }
    }

    private var showsSectionCount: Bool {
        progress.total > 0 && showsDeterminateProgress
    }

    private var accessibilityValue: String {
        if showsSectionCount {
            return "\(progress.completed) of \(progress.total) sections complete. \(progress.failed) failed. \(progress.message)"
        }
        return progress.message
    }
}

struct RegistrationCompletionSummaryView: View {
    let summary: RegistrationCompletionSummary

    private let metricColumns = [
        GridItem(.adaptive(minimum: 84), spacing: 8)
    ]
    private let orientationColumns = [
        GridItem(.adaptive(minimum: 150), spacing: 8)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(BrainBuilderTheme.mint)
                    .accessibilityHidden(true)
                Text("Registration complete")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 8)
                Text("\(summary.statusCounts.total) sections")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 8) {
                RegistrationSummaryMetric(
                    title: "Affine done",
                    value: summary.statusCounts.affineDone,
                    color: .blue
                )
                RegistrationSummaryMetric(
                    title: "Needs review",
                    value: summary.statusCounts.needsReview,
                    color: BrainBuilderTheme.amber
                )
                RegistrationSummaryMetric(
                    title: "Accepted",
                    value: summary.statusCounts.accepted,
                    color: BrainBuilderTheme.mint
                )
                RegistrationSummaryMetric(
                    title: "Failed",
                    value: summary.statusCounts.failed,
                    color: BrainBuilderTheme.rose
                )
            }

            Divider().overlay(BrainBuilderTheme.border)

            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tissue-mask IoU")
                        .font(.caption.weight(.medium))
                    Text(iouCoverageText)
                        .font(.caption2)
                        .foregroundStyle(iouCoverageColor)
                }
                Spacer(minLength: 8)
                RegistrationSummaryValue(
                    title: "Median",
                    value: formattedIoU(summary.medianMajorRegionIoU)
                )
                RegistrationSummaryValue(
                    title: "P10",
                    value: formattedIoU(summary.p10MajorRegionIoU)
                )
            }

            Text("Tissue overlap measures the outer shape; it does not validate internal brain regions.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider().overlay(BrainBuilderTheme.border)

            HStack {
                Text("Montage orientation")
                    .font(.caption.weight(.medium))
                Spacer(minLength: 8)
                Text("\(summary.groupOrientations.count) groups")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: orientationColumns, alignment: .leading, spacing: 7) {
                ForEach(summary.groupOrientations) { group in
                    HStack(spacing: 6) {
                        Text(group.displayGroupID)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(group.state.title)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(group.state.isConsistent ? Color.secondary : BrainBuilderTheme.amber)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 6)
                    .background(BrainBuilderTheme.surfaceSoft, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }
        }
        .padding(10)
        .background(BrainBuilderTheme.surfaceSoft, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(BrainBuilderTheme.border, lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Registration result summary")
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier("registration-completion-summary")
    }

    private var iouCoverageText: String {
        var components = [
            "\(summary.measuredMajorRegionIoUCount)/\(summary.statusCounts.total) measured"
        ]
        if summary.invalidMajorRegionIoUCount > 0 {
            components.append("\(summary.invalidMajorRegionIoUCount) invalid")
        }
        if summary.missingMajorRegionIoUCount > 0 {
            components.append("\(summary.missingMajorRegionIoUCount) missing")
        }
        return components.joined(separator: " · ")
    }

    private var iouCoverageColor: Color {
        summary.invalidMajorRegionIoUCount > 0 || summary.missingMajorRegionIoUCount > 0
            ? BrainBuilderTheme.amber
            : .secondary
    }

    private func formattedIoU(_ value: Double?) -> String {
        value.map { String(format: "%.3f", $0) } ?? "—"
    }

    private var accessibilityValue: String {
        let counts = summary.statusCounts
        var value = "\(counts.affineDone) affine, \(counts.needsReview) need review, "
            + "\(counts.accepted) accepted, \(counts.failed) failed. "
        if let median = summary.medianMajorRegionIoU, let p10 = summary.p10MajorRegionIoU {
            value += "Tissue-mask I O U median \(formattedIoU(median)), P 10 \(formattedIoU(p10)), "
                + "\(summary.measuredMajorRegionIoUCount) of \(counts.total) measured. "
        } else {
            value += "No valid tissue-mask I O U measurements. "
        }
        if summary.invalidMajorRegionIoUCount > 0 {
            value += "\(summary.invalidMajorRegionIoUCount) invalid I O U values. "
        }
        if summary.missingMajorRegionIoUCount > 0 {
            value += "\(summary.missingMajorRegionIoUCount) missing I O U values. "
        }
        value += summary.groupOrientations.map {
            "\($0.displayGroupID): \($0.state.accessibilityTitle)"
        }.joined(separator: ". ")
        return value
    }
}

private struct RegistrationSummaryMetric: View {
    let title: String
    let value: Int
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 2)
            Text("\(value)")
                .font(.caption.weight(.semibold).monospacedDigit())
        }
    }
}

private struct RegistrationSummaryValue: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold).monospacedDigit())
        }
    }
}

private struct RegistrationQueueNavigation: View {
    @ObservedObject var store: BrainProjectStore

    private var slices: [SliceRegistrationRecord] {
        store.registrationProject?.slices ?? []
    }

    private var selectedIndex: Int? {
        guard !slices.isEmpty else { return nil }
        guard let selectedID = store.selectedRegistrationSliceID else { return 0 }
        return slices.firstIndex(where: { $0.id == selectedID })
    }

    var body: some View {
        SectionNavigationControls(
            selectedIndex: selectedIndex,
            totalCount: slices.count,
            isDisabled: store.isBusy,
            moveSelection: moveSelection
        )
    }

    private func moveSelection(by offset: Int) {
        guard let selectedIndex else { return }
        let targetIndex = selectedIndex + offset
        guard slices.indices.contains(targetIndex) else { return }
        store.selectedRegistrationSliceID = slices[targetIndex].id
    }
}

private struct AtlasReviewViewer: View {
    var slice: SliceRegistrationRecord?
    var volumeSlice: VolumeSlice?
    @Binding var overlayMode: ReviewOverlayMode
    var structuresPath: String
    var orientationState: SectionOrientationState
    var retrospectiveVisibility: Brain3DRetrospectiveOverlayVisibility
    var retrospectiveSnapshot: Brain3DRetrospectiveOverlaySnapshot?

    var body: some View {
        ZStack {
            if !orientationState.permitsSectionRasterPresentation {
                VStack(spacing: 12) {
                    Image(systemName: orientationStateImage)
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(orientationStateTitle)
                        .font(.title3.weight(.semibold))
                    Text(orientationState.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }
                .padding(24)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("atlas-review-orientation-state")
            } else if let slice {
                RegistrationArtifactImage(
                    slice: slice,
                    volumeSlice: volumeSlice,
                    overlayMode: $overlayMode,
                    structuresPath: structuresPath,
                    retrospectiveVisibility: retrospectiveVisibility,
                    retrospectiveSnapshot: retrospectiveSnapshot
                )
                    .padding(14)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "scope")
                        .font(.system(size: 46, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("No slice selected")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white)
    }

    private var orientationStateImage: String {
        if case .unavailable = orientationState {
            return "exclamationmark.triangle"
        }
        return "scope"
    }

    private var orientationStateTitle: String {
        if case .unavailable = orientationState {
            return "Canonical orientation unavailable"
        }
        return "Canonical orientation pending"
    }
}

private struct RegistrationArtifactImage: View {
    var slice: SliceRegistrationRecord
    var volumeSlice: VolumeSlice?
    @Binding var overlayMode: ReviewOverlayMode
    var structuresPath: String
    var retrospectiveVisibility: Brain3DRetrospectiveOverlayVisibility
    var retrospectiveSnapshot: Brain3DRetrospectiveOverlaySnapshot?

    @State private var regionLookup: AtlasRegionLookup?
    @State private var regionLookupError: String?
    @State private var regionInteraction = AtlasRegionInteractionState()
    @State private var keyboardAnnotationPixel: CGPoint?
    @State private var retrospectiveROIMaskImage: NSImage?
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var atlasOpacity = 0.35
    @GestureState private var magnification: CGFloat = 1
    @GestureState private var dragTranslation: CGSize = .zero
    @FocusState private var isRegionCursorFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            canvasControls
            if let path = artifactPath,
               let image = NSImage(contentsOfFile: path),
               let imagePixelSize = image.brainBuilderPixelSize {
                interactiveArtifact(image: image, imagePixelSize: imagePixelSize)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                regionContextRail(imagePixelSize: imagePixelSize)
            } else {
                ZStack(alignment: .bottom) {
                    ReviewSliceImage(slice: slice, volumeSlice: volumeSlice)
                    Text(missingArtifactMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .padding(12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                regionContextRail(imagePixelSize: nil)
            }
        }
        .onAppear {
            if regionInteraction.synchronize(to: interactionContext) {
                keyboardAnnotationPixel = nil
            }
        }
        .onChange(of: interactionContext) { _, newContext in
            if regionInteraction.synchronize(to: newContext) {
                keyboardAnnotationPixel = nil
                fitImage()
            }
        }
        .onChange(of: overlayMode) { _, newMode in
            regionInteraction.setDirectLookupEnabled(newMode.supportsDirectRegionLookup)
            if !newMode.supportsDirectRegionLookup {
                keyboardAnnotationPixel = nil
            }
        }
        .onChange(of: retrospectiveVisibility.showsAllenROIMask) { _, _ in
            refreshRetrospectiveROIMask()
        }
        .onChange(of: retrospectiveSnapshot) { _, _ in
            refreshRetrospectiveROIMask()
        }
        .task(id: interactionContext) {
            if regionInteraction.synchronize(to: interactionContext) {
                keyboardAnnotationPixel = nil
            }
            await loadRegionLookup()
        }
    }

    private func interactiveArtifact(image: NSImage, imagePixelSize: CGSize) -> some View {
        GeometryReader { proxy in
            let baseFit = AtlasImageGeometry.aspectFitRect(
                imageSize: imagePixelSize,
                containerSize: proxy.size
            )
            let viewport = currentViewport(containerSize: proxy.size)
            let fitted = viewport.displayRect(baseFit)

            ZStack {
                Color.white

                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fitted.width, height: fitted.height)
                    .position(x: fitted.midX, y: fitted.midY)
                    .accessibilityHidden(true)

                if overlayMode == .opacity,
                   let path = slice.artifacts?.atlasReferencePath,
                   let atlasImage = NSImage(contentsOfFile: path),
                   atlasImage.brainBuilderPixelSize == imagePixelSize {
                    Image(nsImage: atlasImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fitted.width, height: fitted.height)
                        .position(x: fitted.midX, y: fitted.midY)
                        .opacity(atlasOpacity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                if canShowRetrospectiveLayers,
                   retrospectiveVisibility.showsAllenROIMask,
                   let retrospectiveROIMaskImage {
                    Image(nsImage: retrospectiveROIMaskImage)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: fitted.width, height: fitted.height)
                        .position(x: fitted.midX, y: fitted.midY)
                        .blendMode(.screen)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                if canShowRetrospectiveLayers,
                   let retrospectiveSnapshot,
                   let placement = volumeSlice?.atlasPlacement {
                    Brain3DRetrospectiveSliceOverlay(
                        snapshot: retrospectiveSnapshot,
                        visibility: retrospectiveVisibility,
                        placement: placement,
                        imagePixelSize: imagePixelSize
                    )
                    .scaleEffect(viewport.zoom)
                    .offset(viewport.pan)
                    .allowsHitTesting(false)
                }

                RoundedRectangle(cornerRadius: 4)
                    .stroke(BrainBuilderTheme.border, lineWidth: 1)
                    .frame(width: fitted.width, height: fitted.height)
                    .position(x: fitted.midX, y: fitted.midY)
                    .allowsHitTesting(false)

                if overlayMode.supportsDirectRegionLookup,
                   let pinned = regionInteraction.pinnedRegion,
                   let point = AtlasImageGeometry.containerPoint(
                       annotationX: pinned.annotationX,
                       annotationY: pinned.annotationY,
                       imageSize: imagePixelSize,
                       containerSize: proxy.size
                   ) {
                    AtlasPinnedRegionMarker()
                        .position(viewport.displayPoint(point))
                        .allowsHitTesting(false)
                }

                if overlayMode.supportsDirectRegionLookup,
                   isRegionCursorFocused,
                   let keyboardAnnotationPixel,
                   let point = AtlasImageGeometry.containerPoint(
                       annotationX: Int(keyboardAnnotationPixel.x),
                       annotationY: Int(keyboardAnnotationPixel.y),
                       imageSize: imagePixelSize,
                       containerSize: proxy.size
                   ) {
                    AtlasKeyboardRegionCursor()
                        .position(viewport.displayPoint(point))
                        .allowsHitTesting(false)
                }

                regionInteractionSurface(
                    imagePixelSize: imagePixelSize,
                    containerSize: proxy.size
                )
                .simultaneousGesture(
                    MagnificationGesture()
                        .updating($magnification) { value, state, _ in state = value }
                        .onEnded { value in
                            zoom = min(8, max(1, zoom * value))
                            if zoom == 1 { pan = .zero }
                        }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 3)
                        .updating($dragTranslation) { value, state, _ in
                            if zoom > 1 { state = value.translation }
                        }
                        .onEnded { value in
                            if zoom > 1 {
                                pan.width += value.translation.width
                                pan.height += value.translation.height
                            }
                        }
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    private var canvasControls: some View {
        HStack(spacing: 8) {
            Button("Fit") { fitImage() }
                .help("Fit the whole section in the canvas")
            Button { setZoom(zoom / 1.25) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .disabled(zoom <= 1)
            .accessibilityLabel("Zoom out")
            Text("\(Int((zoom * magnification * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .frame(width: 44)
            Button { setZoom(zoom * 1.25) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .disabled(zoom >= 8)
            .accessibilityLabel("Zoom in")

            if overlayMode == .opacity {
                Divider().frame(height: 16)
                Text("Atlas")
                    .font(.caption)
                Slider(value: $atlasOpacity, in: 0...1)
                    .frame(minWidth: 60, maxWidth: 140)
                    .accessibilityLabel("Atlas overlay opacity")
                Text("\(Int((atlasOpacity * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 32)
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .help("Pinch or use the zoom buttons to magnify. Drag a magnified image to pan; Fit resets the view.")
        .accessibilityIdentifier("registration-canvas-controls")
    }

    private func fitImage() {
        zoom = 1
        pan = .zero
    }

    private func setZoom(_ value: CGFloat) {
        zoom = min(8, max(1, value))
        if zoom == 1 { pan = .zero }
    }

    private func currentViewport(containerSize: CGSize) -> RegistrationCanvasViewport {
        RegistrationCanvasViewport(
            containerSize: containerSize,
            zoom: min(8, max(1, zoom * magnification)),
            pan: CGSize(
                width: pan.width + dragTranslation.width,
                height: pan.height + dragTranslation.height
            )
        )
    }

    private func regionInteractionSurface(
        imagePixelSize: CGSize,
        containerSize: CGSize
    ) -> some View {
        let pointerSurface = Color.clear
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                updateHover(
                    phase,
                    imagePixelSize: imagePixelSize,
                    containerSize: containerSize
                )
            }
            .gesture(
                SpatialTapGesture().onEnded { value in
                    pinRegion(
                        at: value.location,
                        imagePixelSize: imagePixelSize,
                        containerSize: containerSize
                    )
                }
            )

        let keyboardSurface = pointerSurface
            .focusable(overlayMode.supportsDirectRegionLookup)
            .focused($isRegionCursorFocused)
            .onChange(of: isRegionCursorFocused) { _, focused in
                if focused, keyboardAnnotationPixel == nil {
                    moveKeyboardCursor(deltaX: 0, deltaY: 0, imagePixelSize: imagePixelSize)
                }
            }
            .onKeyPress(
                keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .return, .space, .escape]
            ) { keyPress in
                handleRegionKeyPress(keyPress, imagePixelSize: imagePixelSize)
            }

        let accessibleSurface = keyboardSurface
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Atlas region cursor")
            .accessibilityValue(imageAccessibilityValue)
            .accessibilityHint(imageAccessibilityHint)
            .accessibilityAction {
                pinKeyboardRegion(imagePixelSize: imagePixelSize)
            }
            .accessibilityAction(.escape) {
                regionInteraction.clearPin()
            }
            .accessibilityAction(named: "Move left") {
                moveKeyboardCursor(deltaX: -1, deltaY: 0, imagePixelSize: imagePixelSize)
            }
            .accessibilityAction(named: "Move right") {
                moveKeyboardCursor(deltaX: 1, deltaY: 0, imagePixelSize: imagePixelSize)
            }
            .accessibilityAction(named: "Move up") {
                moveKeyboardCursor(deltaX: 0, deltaY: -1, imagePixelSize: imagePixelSize)
            }
            .accessibilityAction(named: "Move down") {
                moveKeyboardCursor(deltaX: 0, deltaY: 1, imagePixelSize: imagePixelSize)
            }
        return accessibleSurface
    }

    @ViewBuilder
    private func regionContextRail(imagePixelSize: CGSize?) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Group {
                if !overlayMode.supportsDirectRegionLookup {
                    if let pinnedRegion = regionInteraction.pinnedRegion {
                        AtlasRegionReadout(
                            region: pinnedRegion,
                            presentation: .pinnedFromAtlasView,
                            sliceStatus: slice.status
                        )
                    } else {
                        RegionLookupNotice(
                            title: "Region names unavailable in Track",
                            detail: "Track uses source-image coordinates. Show Overlay for exact Allen labels.",
                            systemImage: "scope"
                        )
                    }
                } else if let region = regionInteraction.displayedRegion {
                    AtlasRegionReadout(
                        region: region,
                        presentation: regionInteraction.isDisplayingPreview ? .preview : .pinned,
                        sliceStatus: slice.status
                    )
                } else if let regionLookupError {
                    RegionLookupNotice(
                        title: "Region lookup unavailable",
                        detail: regionLookupError,
                        systemImage: "exclamationmark.triangle"
                    )
                } else if imagePixelSize == nil {
                    RegionLookupNotice(
                        title: "Region lookup unavailable",
                        detail: "Generate a registration review artifact to inspect Allen labels.",
                        systemImage: "photo.badge.exclamationmark"
                    )
                } else if let mismatch = imagePixelSize.flatMap({ dimensionMismatch(imagePixelSize: $0) }) {
                    RegionLookupNotice(
                        title: "Region lookup unavailable",
                        detail: mismatch,
                        systemImage: "exclamationmark.triangle"
                    )
                } else if regionLookup == nil {
                    RegionLookupNotice(
                        title: "Loading Allen region names",
                        detail: "Reading the annotation IDs and BrainGlobe structure hierarchy.",
                        systemImage: "hourglass"
                    )
                } else {
                    RegionLookupNotice(
                        title: "Hover to identify a brain region",
                        detail: "Click to pin, or focus the image and use arrow keys plus Return.",
                        systemImage: "cursorarrow.rays"
                    )
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 7) {
                if !overlayMode.supportsDirectRegionLookup {
                    Button {
                        overlayMode = .opacity
                    } label: {
                        Label("Show Overlay", systemImage: "square.2.layers.3d")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityLabel("Show atlas overlay")
                    .accessibilityHint("Switches to Overlay, where exact Allen region names are available.")
                }

                if let pinnedRegion = regionInteraction.pinnedRegion {
                    Button {
                        regionInteraction.clearPin()
                    } label: {
                        Label("Clear Pin", systemImage: "pin.slash")
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Clear pinned atlas region")
                    .accessibilityHint("Clears \(pinnedRegion.name), \(pinnedRegion.acronym).")
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .background(BrainBuilderTheme.surfaceSoft, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(BrainBuilderTheme.border, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Atlas region context")
        .accessibilityIdentifier("atlas-region-context-rail")
    }

    private func updateHover(
        _ phase: HoverPhase,
        imagePixelSize: CGSize,
        containerSize: CGSize
    ) {
        guard overlayMode.supportsDirectRegionLookup else {
            regionInteraction.updateHover(nil)
            return
        }
        switch phase {
        case .active(let location):
            regionInteraction.updateHover(
                region(
                    at: location,
                    imagePixelSize: imagePixelSize,
                    containerSize: containerSize
                )
            )
        case .ended:
            regionInteraction.updateHover(nil)
        }
    }

    private func pinRegion(
        at location: CGPoint,
        imagePixelSize: CGSize,
        containerSize: CGSize
    ) {
        guard overlayMode.supportsDirectRegionLookup,
              let region = region(
                  at: location,
                  imagePixelSize: imagePixelSize,
                  containerSize: containerSize
              ) else {
            return
        }
        regionInteraction.pin(region)
        keyboardAnnotationPixel = CGPoint(x: region.annotationX, y: region.annotationY)
    }

    private func handleRegionKeyPress(
        _ keyPress: KeyPress,
        imagePixelSize: CGSize
    ) -> KeyPress.Result {
        guard overlayMode.supportsDirectRegionLookup else { return .ignored }
        if keyPress.key == .leftArrow {
            moveKeyboardCursor(deltaX: -1, deltaY: 0, imagePixelSize: imagePixelSize)
        } else if keyPress.key == .rightArrow {
            moveKeyboardCursor(deltaX: 1, deltaY: 0, imagePixelSize: imagePixelSize)
        } else if keyPress.key == .upArrow {
            moveKeyboardCursor(deltaX: 0, deltaY: -1, imagePixelSize: imagePixelSize)
        } else if keyPress.key == .downArrow {
            moveKeyboardCursor(deltaX: 0, deltaY: 1, imagePixelSize: imagePixelSize)
        } else if keyPress.key == .return || keyPress.key == .space {
            pinKeyboardRegion(imagePixelSize: imagePixelSize)
        } else if keyPress.key == .escape {
            regionInteraction.clearPin()
        } else {
            return .ignored
        }
        return .handled
    }

    private func moveKeyboardCursor(
        deltaX: Int,
        deltaY: Int,
        imagePixelSize: CGSize
    ) {
        guard overlayMode.supportsDirectRegionLookup,
              dimensionMismatch(imagePixelSize: imagePixelSize) == nil,
              let regionLookup,
              imagePixelSize.width >= 1,
              imagePixelSize.height >= 1 else {
            return
        }
        let start = keyboardAnnotationPixel
            ?? regionInteraction.pinnedRegion.map {
                CGPoint(x: $0.annotationX, y: $0.annotationY)
            }
            ?? CGPoint(x: floor(imagePixelSize.width / 2), y: floor(imagePixelSize.height / 2))
        let step = max(1, Int(round(min(imagePixelSize.width, imagePixelSize.height) / 120)))
        let x = min(
            Int(imagePixelSize.width) - 1,
            max(0, Int(start.x) + deltaX * step)
        )
        let y = min(
            Int(imagePixelSize.height) - 1,
            max(0, Int(start.y) + deltaY * step)
        )
        keyboardAnnotationPixel = CGPoint(x: x, y: y)
        regionInteraction.updateHover(regionLookup.region(x: x, y: y))
    }

    private func pinKeyboardRegion(imagePixelSize: CGSize) {
        if keyboardAnnotationPixel == nil {
            moveKeyboardCursor(deltaX: 0, deltaY: 0, imagePixelSize: imagePixelSize)
        }
        guard let keyboardAnnotationPixel,
              let regionLookup else { return }
        regionInteraction.pin(
            regionLookup.region(
                x: Int(keyboardAnnotationPixel.x),
                y: Int(keyboardAnnotationPixel.y)
            )
        )
    }

    private func region(
        at location: CGPoint,
        imagePixelSize: CGSize,
        containerSize: CGSize
    ) -> AtlasRegionHit? {
        guard let regionLookup,
              dimensionMismatch(imagePixelSize: imagePixelSize) == nil,
              let pixel = AtlasImageGeometry.annotationPixel(
                  at: currentViewport(containerSize: containerSize).imagePoint(location),
                  imageSize: imagePixelSize,
                  containerSize: containerSize
              ) else {
            return nil
        }
        return regionLookup.region(x: pixel.x, y: pixel.y)
    }

    private func dimensionMismatch(imagePixelSize: CGSize) -> String? {
        guard let annotation = regionLookup?.annotation else { return nil }
        guard annotation.width == Int(imagePixelSize.width),
              annotation.height == Int(imagePixelSize.height) else {
            return "The review image and annotation grid have different dimensions; no label was inferred."
        }
        return nil
    }

    private var interactionContext: AtlasRegionInteractionContext {
        AtlasRegionInteractionContext(
            sliceID: slice.id,
            annotationPath: annotationPath,
            structuresPath: structuresPath,
            registrationRevision: slice.transformChain.transforms
                .filter { $0.kind == .affine }
                .map(\.createdAt)
                .max()
        )
    }

    private func loadRegionLookup() async {
        regionLookup = nil
        regionLookupError = nil

        guard let annotationPath else {
            regionLookupError = "Run affine registration to generate the atlas annotation grid."
            return
        }

        let annotationURL = URL(fileURLWithPath: annotationPath)
        let structuresURL = URL(fileURLWithPath: structuresPath)
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try AtlasRegionLookup(annotationURL: annotationURL, structuresURL: structuresURL)
            }.value
            try Task.checkCancellation()
            regionLookup = loaded
            refreshRetrospectiveROIMask()
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            regionLookupError = error.localizedDescription
        }
    }

    private var artifactPath: String? {
        guard let artifacts = slice.artifacts else { return nil }
        switch overlayMode {
        case .histology, .opacity:
            return artifacts.registeredImagePath
        case .atlas:
            return artifacts.atlasReferencePath
        case .track:
            return artifacts.trackOverlayPath
        case .borders:
            return artifacts.boundaryImagePath
        case .checkerboard:
            return artifacts.checkerboardImagePath
        case .difference:
            return artifacts.differenceImagePath
        }
    }

    private var annotationPath: String? {
        slice.artifacts?.annotationImagePath
    }

    private var canShowRetrospectiveLayers: Bool {
        slice.status == .accepted
            && volumeSlice?.atlasPlacement?.isReviewed == true
            && retrospectiveSnapshot?.usableForNavigation == false
    }

    private func refreshRetrospectiveROIMask() {
        guard canShowRetrospectiveLayers,
              retrospectiveVisibility.showsAllenROIMask,
              let retrospectiveSnapshot,
              !retrospectiveSnapshot.allenROIs.isEmpty,
              let regionLookup else {
            retrospectiveROIMaskImage = nil
            return
        }
        retrospectiveROIMaskImage = regionLookup
            .retrospectiveROIMask(for: retrospectiveSnapshot.allenROIs)
            .image()
    }

    private var missingArtifactMessage: String {
        "Run Auto Register All to generate the real \(overlayMode.title.lowercased()) artifact"
    }

    private var imageAccessibilityValue: String {
        if !overlayMode.supportsDirectRegionLookup {
            if let pinnedRegion = regionInteraction.pinnedRegion {
                return "Track view. Direct region lookup is unavailable. Pinned from atlas view: \(pinnedRegion.name), \(pinnedRegion.acronym)."
            }
            return "Track view. Direct region lookup is unavailable."
        }
        guard let region = regionInteraction.displayedRegion else {
            return "No Allen atlas region selected."
        }
        let state = regionInteraction.isDisplayingPreview ? "Preview" : "Pinned"
        return "\(state): \(region.name), \(region.acronym)."
    }

    private var imageAccessibilityHint: String {
        overlayMode.supportsDirectRegionLookup
            ? "Use arrow keys to move the labeled cursor and Return to pin. Escape clears the pin. Pointer hover and click are also available."
            : "Use Show Overlay in the Atlas region rail for exact Allen labels."
    }
}

private struct AtlasPinnedRegionMarker: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.35))
                .frame(width: 20, height: 20)
            Circle()
                .stroke(.white, lineWidth: 3)
                .frame(width: 15, height: 15)
            Circle()
                .stroke(BrainBuilderTheme.accent, lineWidth: 2)
                .frame(width: 11, height: 11)
        }
        .accessibilityHidden(true)
    }
}

private struct AtlasKeyboardRegionCursor: View {
    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.9), lineWidth: 3)
                .frame(width: 24, height: 24)
            Circle()
                .stroke(BrainBuilderTheme.accent, lineWidth: 2)
                .frame(width: 20, height: 20)
            Rectangle()
                .fill(BrainBuilderTheme.accent)
                .frame(width: 1, height: 30)
            Rectangle()
                .fill(BrainBuilderTheme.accent)
                .frame(width: 30, height: 1)
        }
        .accessibilityHidden(true)
    }
}

private enum AtlasRegionPresentation: Equatable {
    case preview
    case pinned
    case pinnedFromAtlasView

    var title: String {
        switch self {
        case .preview:
            "Preview"
        case .pinned:
            "Pinned"
        case .pinnedFromAtlasView:
            "Pinned from atlas view"
        }
    }

    var systemImage: String {
        switch self {
        case .preview:
            "cursorarrow.rays"
        case .pinned, .pinnedFromAtlasView:
            "pin.fill"
        }
    }
}

private struct AtlasRegionReadout: View {
    var region: AtlasRegionHit
    var presentation: AtlasRegionPresentation
    var sliceStatus: SliceRegistrationStatus

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(regionColor)
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(.white.opacity(0.45), lineWidth: 1))
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(region.acronym)
                        .font(.headline)
                    Label(presentation.title, systemImage: presentation.systemImage)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(
                            presentation == .preview
                                ? BrainBuilderTheme.accent
                                : BrainBuilderTheme.secondaryText
                        )
                }
                Text(region.name)
                    .font(.caption.weight(.medium))
                if let hierarchy = region.hierarchyDescription {
                    Text(hierarchy)
                        .font(.caption2)
                        .foregroundStyle(BrainBuilderTheme.secondaryText)
                        .lineLimit(2)
                }
                Text("Structure \(region.structureID) · pixel \(region.annotationX), \(region.annotationY)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(BrainBuilderTheme.secondaryText)
                Text(reviewState)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(sliceStatus == .accepted ? .green : .orange)
            }
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Atlas region: \(region.name), \(region.acronym)")
        .accessibilityValue(accessibilityValue)
    }

    private var regionColor: Color {
        guard region.rgbTriplet.count == 3 else { return .secondary }
        return Color(
            red: Double(region.rgbTriplet[0]) / 255,
            green: Double(region.rgbTriplet[1]) / 255,
            blue: Double(region.rgbTriplet[2]) / 255
        )
    }

    private var reviewState: String {
        sliceStatus == .accepted
            ? "Reviewed atlas label"
            : "Allen CCF estimate · registration not accepted"
    }

    private var accessibilityValue: String {
        [presentation.title, region.hierarchyDescription, reviewState]
            .compactMap { $0 }
            .joined(separator: ". ")
    }
}

private struct RegionLookupNotice: View {
    var title: String
    var detail: String
    var systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: systemImage)
                .foregroundStyle(BrainBuilderTheme.secondaryText)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.medium))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(BrainBuilderTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(detail)
    }
}

extension NSImage {
    var brainBuilderPixelSize: CGSize? {
        var rect = NSRect(origin: .zero, size: size)
        guard let image = cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return nil
        }
        return CGSize(width: image.width, height: image.height)
    }
}

private struct ReviewSliceImage: View {
    var slice: SliceRegistrationRecord
    var volumeSlice: VolumeSlice?

    var body: some View {
        if let volumeSlice {
            Image(nsImage: volumeSlice.texture)
                .resizable()
                .scaledToFit()
                .background(.black)
        } else if let image = NSImage(contentsOfFile: slice.sourceImagePath) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .background(.black)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "photo")
                    .font(.largeTitle)
                Text(URL(fileURLWithPath: slice.sourceImagePath).lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct AtlasRegistrationInspectorPanel: View {
    @ObservedObject var store: BrainProjectStore
    @State private var selectedHandoffID = ""
    @State private var datasetSubjectID = ""
    @State private var operatorLabel = ""
    @State private var rebindReason = ""
    @State private var mouseLineToken = ""
    @State private var brain3DReviewerLabel = ""
    @State private var brain3DReviewReason = ""
    @State private var selectedBlindTrackIDs: Set<String> = []
    @State private var blindSourcePointIDs = ""
    @State private var blindTargetTrackID = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(BrainBuilderTheme.secondaryText)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Inspector")
                            .font(.caption)
                            .foregroundStyle(BrainBuilderTheme.secondaryText)
                        Text(store.selectedRegistrationSlice?.title ?? "No section")
                            .font(.headline)
                            .lineLimit(1)
                    }
                }

                if let slice = store.selectedRegistrationSlice {
                    inspectorSection("QC") {
                        if let rawAP = slice.qc.rawPoseAPMicrons {
                            KeyValueLine("Raw AP", String(format: "%.0f µm", rawAP))
                        }
                        if let orderedAP = slice.qc.orderedPoseAPMicrons {
                            KeyValueLine("After ordering", String(format: "%.0f µm", orderedAP))
                        }
                        if let adjustment = slice.qc.poseAdjustmentMicrons {
                            KeyValueLine("Ordering shift", String(format: "%+.0f µm", adjustment))
                        }
                        KeyValueLine("Foreground", slice.qc.foregroundCoverage.map { String(format: "%.2f", $0) } ?? "--")
                        KeyValueLine("Landmark RMS", slice.qc.landmarkRMSErrorMicrons.map { String(format: "%.0f um", $0) } ?? "--")
                        KeyValueLine("Tissue overlap", slice.qc.majorRegionIoU.map { String(format: "%.2f", $0) } ?? "--")
                        Text("Outer-shape overlap does not validate internal brain regions.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        ForEach(slice.qc.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }

                    inspectorSection("Selected Slice") {
                        KeyValueLine("Status", slice.status.title)
                        KeyValueLine(
                            "AP estimate",
                            store.sectionOrientationState.permitsSectionRasterPresentation
                                ? slice.pose.map { String(format: "%.0f um", $0.atlasAPMicrons) } ?? "--"
                                : "Pending"
                        )
                        KeyValueLine(
                            "Orientation",
                            store.sectionOrientationState.permitsSectionRasterPresentation
                                ? slice.pose.map { "\(Int($0.rotationDegrees))°" } ?? "--"
                                : "Pending"
                        )
                        KeyValueLine(
                            "Pose source",
                            store.sectionOrientationState.permitsSectionRasterPresentation
                                ? slice.pose?.provenance ?? "--"
                                : "DeepSlice pending"
                        )
                        KeyValueLine("Locked", slice.pose?.manuallyLocked == true ? "Yes" : "No")
                        KeyValueLine("Pixel size", slice.pixelSizeMicrons.map { String(format: "%.3f um", $0) } ?? "Missing")
                        KeyValueLine("Atlas transform", slice.transformChain.hasUsableQuantitativeTransform ? "Usable affine" : "Pose prior only")
                    }

                    collapsibleInspectorSection("Transform Chain") {
                        if slice.transformChain.transforms.isEmpty {
                            Text("No transforms")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(slice.transformChain.transforms) { transform in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(transform.stage.title)
                                        .font(.caption)
                                    Text("\(transform.kind.rawValue), \(transform.engine)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    inspectorSection("Blind Probe Tracks") {
                        let tracks = slice.effectiveProbeTrackCandidates
                        if !tracks.isEmpty {
                            ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                                Button {
                                    store.selectProbeTrackCandidate(track.candidateId)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Candidate \(index + 1)")
                                            Text("\(track.atlasPoints.count) atlas points · RMS \(track.rmseMicrons.map { String(format: "%.1f um", $0) } ?? "--")")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: track.reviewAccepted == true ? "checkmark.circle.fill" : track.status == "rejected" ? "xmark.circle.fill" : "circle")
                                    }
                                }
                                .buttonStyle(.plain)
                                if store.selectedProbeTrackCandidateID == track.candidateId
                                    || (store.selectedProbeTrackCandidateID == nil && index == 0) {
                                    KeyValueLine("Status", track.status)
                                    KeyValueLine("Confidence", String(format: "%.2f", track.confidence))
                                    HStack(spacing: 8) {
                                        Button("Accept") { store.acceptSelectedProbeTrack() }
                                            .disabled(track.reviewAccepted == true || store.isBusy)
                                        Button("Reject") { store.rejectSelectedProbeTrack() }
                                            .disabled(store.isBusy)
                                    }
                                    .controlSize(.small)
                                }
                            }
                        } else {
                            Text("No blind probe-track candidates")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                collapsibleInspectorSection("Mouse Colony Subject") {
                    KeyValueLine("Endpoint", "hhw9l84:3004 via SSH local forward")
                    TextField(
                        "Project subject ID",
                        text: Binding(
                            get: { store.registrationProject?.subjectID ?? "" },
                            set: { store.setRegistrationSubjectID($0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    SecureField("Integration token (blank reuses Keychain)", text: $mouseLineToken)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        Task {
                            await store.verifyMouseLineSubject(suppliedToken: mouseLineToken)
                            mouseLineToken = ""
                        }
                    } label: {
                        Label(
                            store.isVerifyingMouseLineSubject ? "Verifying…" : "Verify Read-only Subject",
                            systemImage: "key.horizontal.fill"
                        )
                    }
                    .disabled(
                        store.registrationProject?.subjectID?.isEmpty != false
                            || store.isBusy
                            || store.isVerifyingMouseLineSubject
                    )

                    if let resolution = store.mouseLineResolution {
                        KeyValueLine("Resolved public ID", resolution.subject.publicId)
                        KeyValueLine("Matched by", resolution.matchedBy.rawValue)
                        KeyValueLine("Colony status", resolution.subject.status)
                        KeyValueLine("Cage", resolution.subject.cage.cageCardId)
                        if let legacyID = resolution.subject.legacyId, !legacyID.isEmpty {
                            KeyValueLine("Legacy ID", legacyID)
                        }
                    }
                    if let receipt = store.registrationProject?.colonySubjectReceipt {
                        KeyValueLine("Verified", receipt.verifiedAt.formatted(date: .abbreviated, time: .standard))
                        KeyValueLine("Record digest", String(receipt.subjectRecordSha256.prefix(16)) + "…")
                    }
                    Text("Read-only identity evidence. The token stays in macOS Keychain and the receipt is excluded from blind reconstruction inputs.")
                        .font(.caption2)
                        .foregroundStyle(BrainBuilderTheme.secondaryText)
                }

                collapsibleInspectorSection("Blind 3D Track Review") {
                    HStack(spacing: 8) {
                        Button {
                            store.buildBlindTrackReview()
                        } label: {
                            Label(
                                store.registrationProject?.blindTrackReviewPreview == nil
                                    ? "Build Blind Tracks"
                                    : "Rebuild Blind Tracks",
                                systemImage: "point.3.connected.trianglepath.dotted"
                            )
                        }
                        .disabled(store.isBusy || store.registrationProject?.blindReviewLocked == true)

                        Button("Reset membership") {
                            selectedBlindTrackIDs = []
                            blindSourcePointIDs = ""
                            blindTargetTrackID = ""
                            store.resetBlindTrackMembership()
                        }
                        .disabled(
                            store.isBusy
                                || store.registrationProject?.blindReviewLocked == true
                                || store.registrationProject?.blindTrackReview == nil
                        )
                    }
                    .controlSize(.small)

                    if let preview = store.registrationProject?.blindTrackReviewPreview {
                        KeyValueLine("Observed finite tracks", "\(preview.tracks.count)")
                        KeyValueLine("Unassigned points", "\(preview.unassignedSourcePointIDs.count)")
                        ForEach(preview.tracks) { track in
                            Toggle(
                                isOn: Binding(
                                    get: { selectedBlindTrackIDs.contains(track.trackId) },
                                    set: { selected in
                                        if selected {
                                            selectedBlindTrackIDs.insert(track.trackId)
                                        } else {
                                            selectedBlindTrackIDs.remove(track.trackId)
                                        }
                                    }
                                )
                            ) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.trackId)
                                        .font(.caption2.monospaced())
                                        .lineLimit(1)
                                    Text(
                                        "\(track.pointCount) points / \(track.distinctSliceCount) slices · "
                                            + String(format: "RMSE %.0f um", track.rmseMicrometres)
                                    )
                                    .font(.caption2)
                                    .foregroundStyle(BrainBuilderTheme.secondaryText)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }

                        TextField(
                            "Source point IDs (comma or whitespace separated)",
                            text: $blindSourcePointIDs
                        )
                        .textFieldStyle(.roundedBorder)

                        HStack(spacing: 8) {
                            Button("Split selected") {
                                if let trackID = selectedBlindTrackIDs.first {
                                    store.splitBlindTrack(
                                        trackID,
                                        sourcePointIDs: parsedBlindSourcePointIDs
                                    )
                                }
                            }
                            .disabled(
                                selectedBlindTrackIDs.count != 1
                                    || parsedBlindSourcePointIDs.count < 3
                                    || store.isBusy
                            )

                            Button("Merge checked") {
                                store.mergeBlindTracks(selectedBlindTrackIDs)
                            }
                            .disabled(selectedBlindTrackIDs.count < 2 || store.isBusy)
                        }
                        .controlSize(.small)

                        Picker("Reassign to", selection: $blindTargetTrackID) {
                            Text("Unassigned").tag("")
                            ForEach(preview.tracks) { track in
                                Text(track.trackId).tag(track.trackId)
                            }
                        }
                        Button("Reassign source points") {
                            store.reassignBlindSourcePoints(
                                parsedBlindSourcePointIDs,
                                to: blindTargetTrackID.isEmpty ? nil : blindTargetTrackID
                            )
                        }
                        .disabled(parsedBlindSourcePointIDs.isEmpty || store.isBusy)
                        .controlSize(.small)
                    } else {
                        Text(
                            "Build after blind slice review. Split, merge, and membership edits use only observed source points; Brain3D plans and ROI context are not passed into reconstruction."
                        )
                        .font(.caption2)
                        .foregroundStyle(BrainBuilderTheme.secondaryText)
                    }

                    Text("Observed endpoints are undirected A/B finite evidence and are not usable for navigation.")
                        .font(.caption2)
                        .foregroundStyle(BrainBuilderTheme.secondaryText)
                }

                collapsibleInspectorSection("Brain3D Plan Context") {
                    Button {
                        store.openBrain3DPlanPanel()
                    } label: {
                        Label("Load Brain3D Plan…", systemImage: "brain.head.profile")
                    }
                    .disabled(store.isBusy)

                    if let imported = store.pendingBrain3DImport {
                        KeyValueLine("Project", imported.projectID)
                        KeyValueLine("Plan subject", imported.subjectID)
                        KeyValueLine("Verified handoffs", "\(imported.handoffs.count)")
                        Picker("Handoff", selection: $selectedHandoffID) {
                            Text("Select explicitly…").tag("")
                            ForEach(imported.handoffs, id: \.handoffID) { handoff in
                                Text(handoff.handoffID ?? "Invalid handoff")
                                    .tag(handoff.handoffID ?? "")
                            }
                        }
                        TextField("Dataset subject ID", text: $datasetSubjectID)
                            .textFieldStyle(.roundedBorder)
                        TextField("Operator label (rebind only)", text: $operatorLabel)
                            .textFieldStyle(.roundedBorder)
                        TextField("Rebind reason (rebind only)", text: $rebindReason)
                            .textFieldStyle(.roundedBorder)
                        Button("Attach selected handoff") {
                            store.setRegistrationSubjectID(datasetSubjectID)
                            store.attachBrain3DHandoff(
                                handoffID: selectedHandoffID,
                                operatorLabel: operatorLabel,
                                rebindReason: rebindReason
                            )
                        }
                        .disabled(selectedHandoffID.isEmpty || store.registrationProject == nil)
                    }

                    if let context = store.registrationProject?.brain3dContext {
                        KeyValueLine("Bound handoff", context.priorReceipt.handoffId)
                        KeyValueLine("Subject binding", context.subjectBinding.state.rawValue)
                        KeyValueLine(
                            "Plan overlays",
                            context.blindReviewLocked ? "Available" : "Hidden until blind lock"
                        )
                        HStack(spacing: 8) {
                            if context.blindReviewLocked {
                                Button("Unlock blind review") { store.unlockBlindTrackReview() }
                            } else {
                                Button("Lock blind review") { store.lockBlindTrackReview() }
                            }
                            Button("Remove context", role: .destructive) {
                                store.clearBrain3DContext()
                            }
                        }
                        .controlSize(.small)

                        if context.blindReviewLocked {
                            Button {
                                store.buildBrain3DMatchReview()
                            } label: {
                                Label(
                                    context.reviewPreview == nil
                                        ? "Build Match Review"
                                        : "Rebuild Match Review",
                                    systemImage: "point.3.connected.trianglepath.dotted"
                                )
                            }
                            .disabled(store.isBusy)
                        }

                        if let preview = context.reviewPreview {
                            KeyValueLine("Observed tracks", "\(preview.tracks.count)")
                            KeyValueLine("Planned shanks", "\(preview.plannedShanks.count)")
                            KeyValueLine("ROI sets", "\(preview.roiSummaries.count)")
                            TextField("Reviewer label", text: $brain3DReviewerLabel)
                                .textFieldStyle(.roundedBorder)
                            TextField("Review reason", text: $brain3DReviewReason)
                                .textFieldStyle(.roundedBorder)

                            if !preview.suggestions.isEmpty {
                                Text("Ranked suggestions")
                                    .font(.caption.weight(.semibold))
                                ForEach(
                                    Array(preview.suggestions.enumerated()),
                                    id: \.offset
                                ) { _, suggestion in
                                    Button {
                                        store.confirmBrain3DSuggestion(
                                            suggestion,
                                            reviewerLabel: brain3DReviewerLabel,
                                            reason: brain3DReviewReason
                                        )
                                    } label: {
                                        Text(
                                            suggestion.shankId.map {
                                                "Confirm \(suggestion.trackId) → \($0)"
                                            } ?? "Confirm \(suggestion.trackId) → insertion ambiguous"
                                        )
                                    }
                                    .disabled(!brain3DReviewFieldsReady)
                                    .controlSize(.small)
                                }
                            }

                            Text("Observed evidence")
                                .font(.caption.weight(.semibold))
                            ForEach(preview.tracks) { track in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(track.trackId)
                                            .font(.caption2.monospaced())
                                            .lineLimit(1)
                                        Spacer()
                                        Button("Unmatched") {
                                            store.markBrain3DTrackUnmatched(
                                                track.trackId,
                                                reviewerLabel: brain3DReviewerLabel,
                                                reason: brain3DReviewReason
                                            )
                                        }
                                        .disabled(!brain3DReviewFieldsReady)
                                    }
                                    Text(brain3DLOSODescription(track.leaveOneSectionOutSensitivity))
                                        .font(.caption2)
                                        .foregroundStyle(BrainBuilderTheme.secondaryText)
                                    Text(
                                        String(
                                            format: "Finite support %.0f um · fit RMSE %.0f um · %d points / %d slices",
                                            track.supportLengthMicrometres,
                                            track.rmseMicrometres,
                                            track.pointCount,
                                            track.distinctSliceCount
                                        )
                                    )
                                    .font(.caption2)
                                    .foregroundStyle(BrainBuilderTheme.secondaryText)
                                }
                                .controlSize(.mini)
                            }

                            Text("Planned physical shanks")
                                .font(.caption.weight(.semibold))
                            ForEach(preview.plannedShanks) { shank in
                                HStack {
                                    Text("\(shank.insertionSnapshotId.prefix(8)) · \(shank.shankId)")
                                        .font(.caption2.monospaced())
                                    Spacer()
                                    Button("Not observed") {
                                        store.markBrain3DShankNotObserved(
                                            shank,
                                            reviewerLabel: brain3DReviewerLabel,
                                            reason: brain3DReviewReason
                                        )
                                    }
                                    .disabled(!brain3DReviewFieldsReady)
                                }
                                .controlSize(.mini)
                            }

                            if !preview.roiSummaries.isEmpty {
                                Text("ROI traversal evidence")
                                    .font(.caption.weight(.semibold))
                                ForEach(preview.roiSummaries) { summary in
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text(summary.name)
                                                .font(.caption)
                                            Spacer()
                                            Text(summary.scope)
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(BrainBuilderTheme.secondaryText)
                                        }
                                        KeyValueLine(
                                            "Planned traversal",
                                            String(
                                                format: "%.0f um · %d member(s)",
                                                summary.planned.totalTraversalLengthMicrometres,
                                                summary.planned.traversedMemberKeys.count
                                            )
                                        )
                                        KeyValueLine(
                                            "Observed traversal",
                                            String(
                                                format: "%.0f um · %d member(s)",
                                                summary.observed.totalTraversalLengthMicrometres,
                                                summary.observed.traversedMemberKeys.count
                                            )
                                        )
                                        KeyValueLine(
                                            "Member overlap",
                                            "\(summary.intersection.traversedMemberKeys.count) / \(summary.union.traversedMemberKeys.count) union"
                                        )
                                    }
                                    .padding(8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(BrainBuilderTheme.surfaceRaised)
                                    )
                                }
                            }

                            ForEach(context.reviewDispositions) { disposition in
                                HStack {
                                    Text(disposition.state.rawValue)
                                        .font(.caption2)
                                    Spacer()
                                    Button(role: .destructive) {
                                        store.clearBrain3DDisposition(disposition.id)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                }
                                .controlSize(.mini)
                            }
                            if context.manualReviewBlockers.isEmpty {
                                Label("Manual review complete", systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            } else {
                                ForEach(context.manualReviewBlockers, id: \.self) { blocker in
                                    Text(blocker)
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                            Text("Retrospective evidence only — unavailable for navigation, safety, or clearance decisions.")
                                .font(.caption2)
                                .foregroundStyle(BrainBuilderTheme.secondaryText)
                        }
                    }
                }

                if let project = store.registrationProject {
                    inspectorSection("Export Blockers") {
                        let blockers = project.blockersForAtlasExport
                        if blockers.isEmpty {
                            Label("Ready for atlas export", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            ForEach(blockers, id: \.self) { blocker in
                                Label(blocker, systemImage: "xmark.octagon")
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                            }
                        }
                    }

                    inspectorSection("Channels") {
                        ChannelRoleEditorView(store: store)
                    }
                }

                if let result = store.lastWorkerResult {
                    collapsibleInspectorSection("Last Worker Result") {
                        KeyValueLine("Command", result.command)
                        KeyValueLine("Stage", result.stage.rawValue)
                        ForEach(result.messages, id: \.self) { message in
                            Text(message)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    private var brain3DReviewFieldsReady: Bool {
        !brain3DReviewerLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !brain3DReviewReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var parsedBlindSourcePointIDs: Set<String> {
        Set(
            blindSourcePointIDs
                .split { $0 == "," || $0.isWhitespace }
                .map(String.init)
                .filter { !$0.isEmpty }
        )
    }

    private func brain3DLOSODescription(
        _ sensitivity: Brain3DLeaveOneSectionOutSensitivity
    ) -> String {
        guard sensitivity.available,
              let maximumAngle = sensitivity.maximumAxisAngleDegrees,
              let maximumSeparation = sensitivity.maximumLineSeparationMicrometres,
              let heldOutRMS = sensitivity.rmsHeldOutResidualMicrometres else {
            return "LOSO sensitivity unavailable · \(sensitivity.reason ?? "insufficient section support")"
        }
        return String(
            format: "LOSO sensitivity · max Δaxis %.2f° · max line Δ %.0f um · held-out RMS %.0f um",
            maximumAngle,
            maximumSeparation,
            heldOutRMS
        )
    }

    private func collapsibleInspectorSection<Content: View>(
        _ title: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
        } label: {
            Text(title)
                .font(.headline)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func inspectorSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(BrainBuilderTheme.border)
                .frame(height: 1)
        }
    }
}

private struct KeyValueLine: View {
    var key: String
    var value: String

    init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                Text(key)
                    .foregroundStyle(BrainBuilderTheme.secondaryText)
                Spacer(minLength: 10)
                Text(value)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(key)
                    .foregroundStyle(BrainBuilderTheme.secondaryText)
                Text(value)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}

// Rendering and label hit testing share this affine viewport transform.
struct RegistrationCanvasViewport {
    var containerSize: CGSize
    var zoom: CGFloat
    var pan: CGSize

    func displayPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - containerSize.width / 2) * zoom + containerSize.width / 2 + pan.width,
            y: (point.y - containerSize.height / 2) * zoom + containerSize.height / 2 + pan.height
        )
    }

    func imagePoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - containerSize.width / 2 - pan.width) / zoom + containerSize.width / 2,
            y: (point.y - containerSize.height / 2 - pan.height) / zoom + containerSize.height / 2
        )
    }

    func displayRect(_ rect: CGRect) -> CGRect {
        CGRect(
            origin: displayPoint(rect.origin),
            size: CGSize(width: rect.width * zoom, height: rect.height * zoom)
        )
    }
}
