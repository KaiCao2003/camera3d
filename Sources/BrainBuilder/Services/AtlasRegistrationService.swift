import Foundation

struct AtlasRegistrationService {
    private let atlas = AllenCCFReference.default

    func register(_ inputSlices: [VolumeSlice], mode: StackSourceMode) -> RegisteredVolume {
        guard !inputSlices.isEmpty else {
            return RegisteredVolume(slices: [], summary: .empty)
        }

        let sorted = inputSlices.enumerated().map { index, slice in
            RegistrationCandidate(originalIndex: index, slice: slice)
        }
        .sorted { lhs, rhs in
            if lhs.slice.groupID != rhs.slice.groupID {
                return lhs.slice.groupID.localizedStandardCompare(rhs.slice.groupID) == .orderedAscending
            }
            return lhs.slice.title.localizedStandardCompare(rhs.slice.title) == .orderedAscending
        }

        let calibratedWidths = sorted.compactMap { candidate -> Double? in
            guard let width = candidate.slice.physicalWidthMicrons, width > 0 else {
                return nil
            }
            return width
        }
        let medianPhysicalWidth = calibratedWidths.isEmpty ? nil : median(calibratedWidths)
        let apSpan = atlas.reconstructionAPRange.upperBound - atlas.reconstructionAPRange.lowerBound
        let denominator = max(1, sorted.count - 1)

        var registered: [VolumeSlice] = []
        registered.reserveCapacity(sorted.count)

        for (orderIndex, candidate) in sorted.enumerated() {
            var slice = candidate.slice
            let orderFraction = Double(orderIndex) / Double(denominator)
            let apMicrons = atlas.reconstructionAPRange.lowerBound + apSpan * orderFraction
            let originalWidth = max(0.01, slice.width)
            if let medianPhysicalWidth,
               let physicalWidth = slice.physicalWidthMicrons,
               let physicalHeight = slice.physicalHeightMicrons,
               physicalWidth > 0,
               physicalHeight > 0 {
                slice.width = physicalWidth / medianPhysicalWidth
                slice.height = physicalHeight / medianPhysicalWidth
                let physicalScale = slice.width / originalWidth
                slice.offsetX *= physicalScale
                slice.offsetY *= physicalScale
            }
            let atlasScale = 1.0
            let expectedWidth = expectedCortexWidth(orderFraction: orderFraction)
            let measuredWidth = slice.width * atlasScale
            let contourDeviation = abs(measuredWidth - expectedWidth) / max(0.01, expectedWidth)
            let contourScore = (1.0 - contourDeviation).clamped(to: 0...1)

            let confidence = confidenceFor(slice: slice, mode: mode)

            slice.offsetX = slice.offsetX.clamped(to: -0.24...0.24)
            slice.offsetY = slice.offsetY.clamped(to: -0.24...0.24)
            slice.z = atlasZ(forAPMicrons: apMicrons)
            slice.registration = SliceRegistration(
                orderIndex: orderIndex,
                atlasAPMicrons: apMicrons,
                atlasAPIndex10um: Int(round(apMicrons / atlas.voxelSizeMicrons)),
                atlasScale: atlasScale,
                atlasOffsetX: slice.offsetX,
                atlasOffsetY: slice.offsetY,
                confidence: confidence,
                atlasContourScore: contourScore,
                atlasContourDeviation: contourDeviation,
                method: "Allen CCF AP order prior; calibrated section geometry preserved"
            )
            registered.append(slice)
        }

        let confidence = registered.map(\.registration.confidence).reduce(0, +) / Double(registered.count)
        let contourScore = registered.map(\.registration.atlasContourScore).reduce(0, +) / Double(registered.count)
        let contourDeviation = registered.map(\.registration.atlasContourDeviation).reduce(0, +) / Double(registered.count)
        let summary = AtlasRegistrationSummary(
            atlasName: atlas.name,
            method: "Preliminary Allen CCF AP order prior with calibrated section geometry; no image transform",
            sliceCount: registered.count,
            apRangeMicrons: atlas.reconstructionAPRange,
            meanConfidence: confidence,
            meanContourScore: contourScore,
            meanContourDeviation: contourDeviation
        )

        return RegisteredVolume(slices: registered, summary: summary)
    }

    private func atlasZ(forAPMicrons apMicrons: Double) -> Double {
        let normalized = (apMicrons - atlas.reconstructionAPRange.lowerBound)
            / (atlas.reconstructionAPRange.upperBound - atlas.reconstructionAPRange.lowerBound)
        return (normalized - 0.5) * atlas.sceneDepth
    }

    private func confidenceFor(slice: VolumeSlice, mode: StackSourceMode) -> Double {
        let coverageScore = min(1, slice.signal.alphaCoverage / 0.42)
        let channelScore = min(1, max(slice.signal.redMean, slice.signal.greenMean) / 115.0)
        let modeScore = mode == .montageSections ? 0.92 : 0.62
        return (coverageScore * 0.45 + channelScore * 0.35 + modeScore * 0.20).clamped(to: 0...1)
    }

    private func expectedCortexWidth(orderFraction: Double) -> Double {
        // Smooth AP prior: narrow rostral/caudal ends, widest mid-brain coronal sections.
        let bell = sin(Double.pi * orderFraction).clamped(to: 0...1)
        return 0.62 + bell * 0.46
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else {
            return 0
        }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2.0
        }
        return sorted[mid]
    }
}

struct RegisteredVolume {
    var slices: [VolumeSlice]
    var summary: AtlasRegistrationSummary
}

struct AllenCCFReference: Hashable {
    var name: String
    var voxelSizeMicrons: Double
    var dimensionsVoxels: SIMD3<Int>
    var reconstructionAPRange: ClosedRange<Double>
    var sceneDepth: Double

    static let `default` = AllenCCFReference(
        name: "Allen Mouse CCFv3 preview geometry (25 µm)",
        voxelSizeMicrons: 25,
        dimensionsVoxels: SIMD3<Int>(528, 320, 456),
        reconstructionAPRange: 900...12_100,
        // Preserve the atlas AP:RL aspect ratio (528 / 456) in normalized scene units.
        sceneDepth: 1.16
    )
}

private struct RegistrationCandidate {
    var originalIndex: Int
    var slice: VolumeSlice
}
