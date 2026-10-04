import Foundation

struct CortexRegistrationService {
    func register(_ inputSlices: [VolumeSlice], mode: StackSourceMode) -> CortexRegisteredVolume {
        guard !inputSlices.isEmpty else {
            return CortexRegisteredVolume(slices: [], summary: .empty)
        }

        let landmarks = inputSlices.map { estimateCortex(for: $0, mode: mode) }
        let medianWidth = median(landmarks.map { max(0.01, $0.cortexWidth) })

        var output: [VolumeSlice] = []
        output.reserveCapacity(inputSlices.count)

        for (index, var slice) in inputSlices.enumerated() {
            var cortex = landmarks[index]
            let midlineCorrection = cortex.midlineX.clamped(to: -0.24...0.24)

            // Translate each section onto a common midline without scaling it.
            // Width normalization erased the real calibrated brain taper and
            // produced the previous tube-like reconstruction.
            slice.offsetX -= midlineCorrection
            cortex.leftCortexX -= midlineCorrection
            cortex.rightCortexX -= midlineCorrection
            cortex.midlineX = 0
            cortex.method = "foreground-mask bounds aligned by midline; physical scale preserved"
            slice.cortex = cortex
            output.append(slice)
        }

        let meanConfidence = output.map(\.cortex.confidence).reduce(0, +) / Double(output.count)
        let meanSymmetry = output.map(\.cortex.symmetryScore).reduce(0, +) / Double(output.count)

        return CortexRegisteredVolume(
            slices: output,
            summary: CortexRegistrationSummary(
                method: "Foreground-mask bounds aligned by midline with physical scale preserved; no atlas boundary registration",
                sliceCount: output.count,
                meanConfidence: meanConfidence,
                meanSymmetry: meanSymmetry,
                medianCortexWidth: medianWidth
            )
        )
    }

    private func estimateCortex(for slice: VolumeSlice, mode: StackSourceMode) -> CortexRegistration {
        let bounds = slice.signal.tissueBounds
        let imageWidth = max(1.0, Double(slice.signal.imageSize.width))
        let imageHeight = max(1.0, Double(slice.signal.imageSize.height))

        let minX = bounds.minX / imageWidth - 0.5
        let maxX = bounds.maxX / imageWidth - 0.5
        let midX = bounds.midX / imageWidth - 0.5
        let minY = 0.5 - bounds.minY / imageHeight
        let height = bounds.height / imageHeight
        let width = bounds.width / imageWidth

        let left = minX * slice.width + slice.offsetX
        let right = maxX * slice.width + slice.offsetX
        let midline = midX * slice.width + slice.offsetX
        let dorsal = minY * slice.height + slice.offsetY
        let cortexWidth = max(0.01, width * slice.width)

        let symmetry = ImageProcessingService.bilateralAlphaSymmetry(slice.texture)
        let dorsalScore = min(1, max(0, height * 1.65))
        let modeScore = mode == .montageSections ? 0.92 : 0.58
        let confidence = (
            slice.signal.foregroundConfidence * 0.42
            + symmetry.clamped(to: 0...1) * 0.30
            + dorsalScore * 0.16
            + modeScore * 0.12
        ).clamped(to: 0...1)

        return CortexRegistration(
            midlineX: midline,
            dorsalY: dorsal,
            leftCortexX: left,
            rightCortexX: right,
            cortexWidth: cortexWidth,
            symmetryScore: symmetry.clamped(to: 0...1),
            confidence: confidence,
            method: "estimated from foreground mask bounds"
        )
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

struct CortexRegisteredVolume {
    var slices: [VolumeSlice]
    var summary: CortexRegistrationSummary
}
