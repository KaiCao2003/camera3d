import SwiftUI

struct MetadataInspectorView: View {
    @ObservedObject var store: BrainProjectStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let group = store.selectedGroup {
                    MetadataSection(title: "Microscope") {
                        KeyValueRow("Group", group.id)
                        KeyValueRow("Lens", group.metadata.lensName)
                        if let size = group.metadata.originalImageSize {
                            KeyValueRow("Original size", size.description)
                        }
                        if let date = group.metadata.shootingDate {
                            KeyValueRow("Captured", DateFormatter.metadataDateTime.string(from: date))
                        }
                        if let magnification = group.metadata.magnificationPercent {
                            KeyValueRow("Magnification", String(format: "%.1fx", Double(magnification) / 100.0))
                        }
                        if let na = group.metadata.numericalAperture {
                            KeyValueRow("NA", String(format: "%.2f", na))
                        }
                        if let wd = group.metadata.workingDistanceMillimeters {
                            KeyValueRow("Working distance", String(format: "%.2f mm", wd))
                        }
                    }

                    MetadataSection(title: "Channels") {
                        ForEach(group.metadata.channels) { channel in
                            HStack {
                                Circle()
                                    .fill(color(for: channel.pseudoColor))
                                    .frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(channel.name)
                                    Text(channel.isShot ? "captured" : "not captured")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let exposure = channel.exposureSeconds {
                                    Text("\(exposure, specifier: "%.2f") s")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if let volume = store.volume {
                    let quantitativePlanes = volume.slices.filter { $0.atlasPlacement != nil }.count
                    let reviewedPlanes = volume.slices.filter { $0.atlasPlacement?.isReviewed == true }.count
                    MetadataSection(title: "3D Stack") {
                        KeyValueRow("Mode", volume.sourceMode.title)
                        KeyValueRow("Slices", "\(volume.slices.count)")
                        KeyValueRow("Source images", "\(volume.buildSummary.sourceImages)")
                        KeyValueRow("Rejected objects", "\(volume.buildSummary.rejectedComponents)")
                        KeyValueRow("Texture max", "\(volume.buildSummary.maxTexturePixels) px")
                        KeyValueRow("Atlas target", volume.atlasRegistration.atlasName)
                        KeyValueRow("AP prior range", String(format: "%.0f-%.0f um", volume.atlasRegistration.apRangeMicrons.lowerBound, volume.atlasRegistration.apRangeMicrons.upperBound))
                        KeyValueRow("Prior QC", String(format: "%.2f", volume.atlasRegistration.meanConfidence))
                        KeyValueRow("Morphology score", String(format: "%.2f", volume.atlasRegistration.meanContourScore))
                        KeyValueRow("Foreground QC", String(format: "%.2f", volume.buildSummary.meanForegroundConfidence))
                        KeyValueRow("Background removed", String(format: "%.1f%%", volume.buildSummary.meanBackgroundRemoved * 100))
                        KeyValueRow("Cortex method", volume.cortexRegistration.method)
                        KeyValueRow("Cortex geometry QC", String(format: "%.2f", volume.cortexRegistration.meanConfidence))
                        KeyValueRow("Cortex mask symmetry", String(format: "%.2f", volume.cortexRegistration.meanSymmetry))
                        KeyValueRow("Quantitative planes", "\(quantitativePlanes) / \(volume.slices.count)")
                        KeyValueRow("Accepted planes", "\(reviewedPlanes) / \(quantitativePlanes)")
                        KeyValueRow(
                            "Reference source",
                            "Allen CCFv3 root mesh (BrainGlobe)"
                        )
                        KeyValueRow(
                            "Reference status",
                            store.atlas.referenceMeshState.conciseDescription
                        )
                        KeyValueRow(
                            "Surface geometry",
                            store.atlas.referenceMeshState.isLoaded
                                ? "Reference envelope + section planes"
                                : "Section planes only"
                        )
                    }

                    MetadataSection(title: "Pre-registration QC") {
                        KeyValueRow("Level", volume.reliabilityReport.level.title)
                        KeyValueRow("Pre-reg score", String(format: "%.2f", volume.reliabilityReport.score))
                        KeyValueRow("Allen CCF", volume.reliabilityReport.atlasReference.summary)
                        if let folder = volume.reliabilityReport.atlasReference.folderURL {
                            KeyValueRow("Reference folder", folder.path)
                        }

                        ForEach(volume.reliabilityReport.issues) { issue in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: icon(for: issue.severity))
                                    .foregroundStyle(color(for: issue.severity))
                                    .frame(width: 14)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(issue.title)
                                        .font(.caption)
                                    Text(issue.detail)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }

                if let slice = store.selectedVolumeSlice {
                    MetadataSection(title: "Selected Slice") {
                        KeyValueRow("Slice", slice.title)
                        KeyValueRow("Group", slice.groupID)
                        KeyValueRow("Coverage", String(format: "%.1f%%", slice.signal.alphaCoverage * 100))
                        KeyValueRow("Foreground QC", String(format: "%.2f", slice.signal.foregroundConfidence))
                        KeyValueRow("Background removed", String(format: "%.1f%%", slice.signal.backgroundSuppression * 100))
                        KeyValueRow("Mean red", String(format: "%.1f", slice.signal.redMean))
                        KeyValueRow("Mean green", String(format: "%.1f", slice.signal.greenMean))
                        KeyValueRow("AP prior", String(format: "%.0f um", slice.registration.atlasAPMicrons))
                        KeyValueRow("Prior index 10um", "\(slice.registration.atlasAPIndex10um)")
                        KeyValueRow("Prior scale", String(format: "%.2f", slice.registration.atlasScale))
                        KeyValueRow("Morphology score", String(format: "%.2f", slice.registration.atlasContourScore))
                        KeyValueRow("Registration", slice.registration.method)
                        KeyValueRow(
                            "3D plane",
                            slice.atlasPlacement.map { $0.isReviewed ? "Affine, reviewed" : "Affine, review required" }
                                ?? "AP prior only"
                        )
                        KeyValueRow("Cortex width", String(format: "%.2f", slice.cortex.cortexWidth))
                        KeyValueRow("Cortex geometry QC", String(format: "%.2f", slice.cortex.confidence))
                        KeyValueRow("Cortex mask symmetry", String(format: "%.2f", slice.cortex.symmetryScore))
                        KeyValueRow("File", slice.sourceURL.lastPathComponent)
                    }
                }

                MetadataSection(title: "Allen CCF") {
                    Text(atlasGeometryExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(store.atlas.resources) { resource in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(resource.title)
                                    .lineLimit(1)
                                Text(resource.expectedSizeDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: FileManager.default.fileExists(atPath: store.atlas.localURL(for: resource).path) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(FileManager.default.fileExists(atPath: store.atlas.localURL(for: resource).path) ? .green : .secondary)
                        }
                    }
                }
            }
            .padding()
        }
    }

    private var atlasGeometryExplanation: String {
        guard let volume = store.volume else {
            return "Use the Atlas workspace to run DeepSlice pose estimation and SimpleITK affine registration, review the generated overlays, and explicitly accept each transform."
        }
        let quantitativePlanes = volume.slices.filter { $0.atlasPlacement != nil }.count
        let reviewedPlanes = volume.slices.filter { $0.atlasPlacement?.isReviewed == true }.count
        let reference: String
        switch store.atlas.referenceMeshState {
        case .loading:
            reference = "The Allen CCFv3 root reference is being validated; no reference envelope is reported as loaded yet. "
        case .loaded:
            reference = "The translucent envelope is the Allen CCFv3 root reference, not reconstructed specimen tissue. "
        case .unavailable:
            reference = "The Allen CCFv3 root reference mesh is unavailable. "
        case let .failed(message):
            reference = "The Allen CCFv3 root reference mesh failed geometry validation: \(message) "
        }
        guard quantitativePlanes > 0 else {
            return "\(reference)No quantitative specimen plane is available."
        }
        let previewPlanes = quantitativePlanes - reviewedPlanes
        return "\(reference)The view contains \(quantitativePlanes) specimen section planes in physical atlas coordinates: \(reviewedPlanes) accepted and \(previewPlanes) unreviewed previews. No solid specimen surface is inferred from these planes."
    }

    private func color(for pseudoColor: String?) -> Color {
        switch pseudoColor?.lowercased() {
        case "green":
            .green
        case "red":
            .red
        case "blue":
            .blue
        default:
            .secondary
        }
    }

    private func icon(for severity: ReliabilitySeverity) -> String {
        switch severity {
        case .info:
            "info.circle"
        case .warning:
            "exclamationmark.triangle.fill"
        case .failure:
            "xmark.octagon.fill"
        }
    }

    private func color(for severity: ReliabilitySeverity) -> Color {
        switch severity {
        case .info:
            .secondary
        case .warning:
            .orange
        case .failure:
            .red
        }
    }
}

private struct MetadataSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct KeyValueRow: View {
    var key: String
    var value: String

    init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
        }
        .font(.caption)
    }
}
