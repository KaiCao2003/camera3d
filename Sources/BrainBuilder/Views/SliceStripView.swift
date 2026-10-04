import SwiftUI

struct SliceStripView: View {
    @ObservedObject var store: BrainProjectStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var slices: [VolumeSlice] {
        store.volume?.slices ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                BrainBuilderSectionLabel("Section navigator")
                Spacer()
                SectionNavigationControls(
                    selectedIndex: store.selectedVolumeSliceIndex,
                    totalCount: slices.count,
                    moveSelection: store.moveSelectedVolumeSlice
                )
            }
            .padding(.horizontal, 16)

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(slices) { slice in
                            let isSelected = store.selectedSliceID == slice.id
                            Button {
                                store.selectVolumeSlice(id: slice.id)
                            } label: {
                                HStack(spacing: 9) {
                                    Group {
                                        if store.sectionOrientationState.permitsSectionRasterPresentation {
                                            Image(nsImage: slice.texture)
                                                .resizable()
                                                .scaledToFill()
                                        } else {
                                            ZStack {
                                                BrainBuilderTheme.sceneBackgroundColor
                                                Image(systemName: "square.stack.3d.down.right")
                                                    .foregroundStyle(BrainBuilderTheme.secondaryText)
                                            }
                                        }
                                    }
                                    .frame(width: 64, height: 48)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 3)
                                            .stroke(
                                                isSelected ? BrainBuilderTheme.accent : BrainBuilderTheme.border,
                                                lineWidth: isSelected ? 2 : 1
                                            )
                                    }

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(slice.title)
                                            .font(.caption.weight(.semibold))
                                            .lineLimit(1)
                                        Text(
                                            store.sectionOrientationState.permitsSectionRasterPresentation
                                                ? String(format: "AP %.0f µm", slice.registration.atlasAPMicrons)
                                                : "AP pending"
                                        )
                                            .font(.caption2)
                                            .monospacedDigit()
                                            .foregroundStyle(BrainBuilderTheme.secondaryText)
                                    }
                                    .frame(width: 82, alignment: .leading)
                                }
                                .padding(7)
                                .background(
                                    isSelected ? BrainBuilderTheme.surfaceRaised : BrainBuilderTheme.surfaceSoft,
                                    in: RoundedRectangle(cornerRadius: 4)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(
                                            isSelected ? BrainBuilderTheme.accent.opacity(0.34) : Color.clear,
                                            lineWidth: 1
                                        )
                                }
                            }
                            .buttonStyle(.plain)
                            .id(slice.id)
                            .accessibilityLabel(slice.title)
                            .accessibilityValue(
                                store.sectionOrientationState.permitsSectionRasterPresentation
                                    ? "Canonical section. AP \(slice.registration.atlasAPMicrons, specifier: "%.0f") micrometers"
                                    : "Canonical orientation pending. Raw source hidden."
                            )
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                }
                .scrollIndicators(.hidden)
                .onChange(of: store.selectedSliceID) {
                    guard let selectedSliceID = store.selectedSliceID else { return }
                    if reduceMotion {
                        proxy.scrollTo(selectedSliceID, anchor: .center)
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 1)) {
                            proxy.scrollTo(selectedSliceID, anchor: .center)
                        }
                    }
                }
            }
        }
        .padding(.top, 10)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(BrainBuilderTheme.border)
                .frame(height: 1)
        }
    }
}

struct SectionNavigationControls: View {
    var selectedIndex: Int?
    var totalCount: Int
    var isDisabled = false
    var moveSelection: (Int) -> Void

    var body: some View {
        HStack(spacing: 5) {
            Button {
                moveSelection(-1)
            } label: {
                Label("Previous Section", systemImage: "chevron.left")
            }
            .labelStyle(.iconOnly)
            .disabled(isDisabled || selectedIndex == nil || selectedIndex == 0)
            .keyboardShortcut("[", modifiers: .command)
            .help("Previous section (⌘[)")

            Text(positionLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(BrainBuilderTheme.secondaryText)
                .frame(minWidth: 50)
                .accessibilityLabel(accessibilityPositionLabel)

            Button {
                moveSelection(1)
            } label: {
                Label("Next Section", systemImage: "chevron.right")
            }
            .labelStyle(.iconOnly)
            .disabled(
                isDisabled
                    || selectedIndex == nil
                    || selectedIndex == totalCount - 1
            )
            .keyboardShortcut("]", modifiers: .command)
            .help("Next section (⌘])")
        }
        .controlSize(.small)
        .accessibilityElement(children: .contain)
    }

    private var positionLabel: String {
        guard let selectedIndex else { return "-- / --" }
        return "\(selectedIndex + 1) / \(totalCount)"
    }

    private var accessibilityPositionLabel: String {
        guard let selectedIndex else { return "No section selected" }
        return "Section \(selectedIndex + 1) of \(totalCount)"
    }
}
