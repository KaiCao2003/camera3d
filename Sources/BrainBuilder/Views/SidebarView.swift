import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: BrainProjectStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                brand
                datasetCard

                if let groups = store.dataset?.groups {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("Acquisitions", value: "\(groups.count)")
                        ForEach(groups) { group in
                            groupRow(group)
                        }
                    }
                }

                atlasCard
            }
            .padding(14)
        }
        .scrollIndicators(.hidden)
        .background(BrainBuilderTheme.sidebar)
        .navigationSplitViewColumnWidth(min: 240, ideal: 274, max: 320)
    }

    private var brand: some View {
        HStack(spacing: 10) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(BrainBuilderTheme.accent)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text("BrainBuilder")
                    .font(.headline)
                Text("Histology workspace")
                    .font(.caption)
                    .foregroundStyle(BrainBuilderTheme.secondaryText)
            }
        }
        .padding(.horizontal, 2)
    }

    private var datasetCard: some View {
        Button {
            store.selectedGroupID = nil
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive")
                    .foregroundStyle(BrainBuilderTheme.secondaryText)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Dataset")
                        .font(.caption)
                        .foregroundStyle(BrainBuilderTheme.secondaryText)
                    Text(store.dataset?.rootURL.lastPathComponent ?? "No folder open")
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    if let dataset = store.dataset {
                        Text("\(dataset.totalSlices) images  ·  \(store.reviewedSliceCount) sections")
                            .font(.caption2)
                            .foregroundStyle(BrainBuilderTheme.secondaryText)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                store.selectedGroupID == nil ? BrainBuilderTheme.surfaceRaised : Color.clear,
                in: RoundedRectangle(cornerRadius: 4)
            )
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(BrainBuilderTheme.secondaryText)
            Spacer()
            Text(value)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(BrainBuilderTheme.secondaryText)
        }
        .padding(.horizontal, 4)
    }

    private func groupRow(_ group: BrainGroup) -> some View {
        let isSelected = store.selectedGroupID == group.id
        return Button {
            withAnimation(.easeOut(duration: 0.16)) {
                store.selectedGroupID = group.id
            }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: group.montageOverlayURL == nil ? "rectangle.stack.badge.minus" : "square.grid.3x3")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? BrainBuilderTheme.accent : BrainBuilderTheme.secondaryText)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 3) {
                    Text(group.title)
                        .font(.callout.weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(.primary)
                    Text("\(group.slices.count) acquisition tiles")
                        .font(.caption2)
                        .foregroundStyle(BrainBuilderTheme.secondaryText)
                }
                Spacer()
                BrainBuilderStatusDot(
                    color: group.montageOverlayURL == nil ? BrainBuilderTheme.amber : BrainBuilderTheme.mint
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isSelected ? BrainBuilderTheme.surfaceRaised : Color.clear,
                in: RoundedRectangle(cornerRadius: 4)
            )
        }
        .buttonStyle(.plain)
    }

    private var atlasCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "map")
                    .foregroundStyle(BrainBuilderTheme.secondaryText)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Atlas")
                        .font(.caption)
                        .foregroundStyle(BrainBuilderTheme.secondaryText)
                    Text("Allen CCFv3 · 25 µm")
                        .font(.callout.weight(.semibold))
                }
                Spacer()
                BrainBuilderStatusDot(
                    color: store.atlas.isDownloading ? BrainBuilderTheme.amber : BrainBuilderTheme.mint
                )
            }

            Text(store.atlas.status)
                .font(.caption2)
                .foregroundStyle(BrainBuilderTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if store.atlas.isDownloading {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(BrainBuilderTheme.mint)
            }

            HStack(spacing: 8) {
                Button {
                    Task { await store.atlas.downloadReferenceSet() }
                } label: {
                    Label("Sync", systemImage: "arrow.down.circle")
                }
                .disabled(store.atlas.isDownloading)

                Button {
                    store.atlas.openAtlasFolder()
                } label: {
                    Label("Files", systemImage: "folder")
                }
            }
            .buttonStyle(.borderless)
            .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.top, 14)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(BrainBuilderTheme.border)
                .frame(height: 1)
        }
    }
}
