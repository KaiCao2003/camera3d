import Foundation

struct RegistrationReliabilityService {
    private let reference = AllenCCFReference.default

    func verify(
        dataset: BrainDataset,
        slices: [VolumeSlice],
        atlasRegistration: AtlasRegistrationSummary,
        cortexRegistration: CortexRegistrationSummary,
        buildSummary: VolumeBuildSummary,
        mode: StackSourceMode
    ) -> ReliabilityReport {
        guard !slices.isEmpty else {
            return .empty
        }

        let atlasReference = AtlasReferenceVerifier.verify()
        var issues = atlasReference.issues

        if !atlasReference.isComplete {
            issues.append(
                ReliabilityIssue(
                    severity: .warning,
                    title: "Allen CCF reference files incomplete",
                    detail: atlasReference.summary
                )
            )
        }

        issues.append(
            ReliabilityIssue(
                severity: .info,
                title: "3D preview is not atlas-registered",
                detail: "This pre-registration stack summary contains only a heuristic AP prior and foreground-mask cortex geometry. It does not incorporate any later DeepSlice pose or SimpleITK transform from the Atlas workspace, so its cortex boundaries must not be treated as aligned to Allen CCF."
            )
        )

        let missingMetadata = dataset.groups.filter { $0.metadata.archiveURL == nil }
        if !missingMetadata.isEmpty {
            issues.append(
                ReliabilityIssue(
                    severity: .warning,
                    title: "Missing microscope metadata",
                    detail: "\(missingMetadata.count) group(s) have no readable Keyence GCI archive."
                )
            )
        }

        if mode == .montageSections && buildSummary.sourceImages < dataset.groups.count {
            issues.append(
                ReliabilityIssue(
                    severity: .warning,
                    title: "Incomplete montage coverage",
                    detail: "Used \(buildSummary.sourceImages) montage source image(s) for \(dataset.groups.count) XY group(s)."
                )
            )
        }

        if !reference.reconstructionAPRange.contains(atlasRegistration.apRangeMicrons.lowerBound)
            || !reference.reconstructionAPRange.contains(atlasRegistration.apRangeMicrons.upperBound) {
            issues.append(
                ReliabilityIssue(
                    severity: .failure,
                    title: "AP range outside Allen CCF prior",
                    detail: "Estimated AP range \(format(atlasRegistration.apRangeMicrons.lowerBound))-\(format(atlasRegistration.apRangeMicrons.upperBound)) um exceeds the configured Allen CCF extent."
                )
            )
        }

        if !isMonotonic(slices.map(\.registration.atlasAPMicrons)) || !isMonotonic(slices.map(\.z)) {
            issues.append(
                ReliabilityIssue(
                    severity: .failure,
                    title: "Non-monotonic slice order",
                    detail: "Estimated AP coordinates or scene Z positions are not strictly ordered."
                )
            )
        }

        if atlasRegistration.meanConfidence < 0.70 {
            issues.append(
                ReliabilityIssue(
                    severity: .warning,
                    title: "Low AP prior QC",
                    detail: "Mean AP prior QC is \(format(atlasRegistration.meanConfidence)); expected at least 0.70 before atlas registration."
                )
            )
        }

        if atlasRegistration.meanContourScore < 0.60 {
            issues.append(
                ReliabilityIssue(
                    severity: .warning,
                    title: "Weak morphology prior",
                    detail: "Mean morphology score is \(format(atlasRegistration.meanContourScore)); expected at least 0.60 before atlas registration."
                )
            )
        }

        if cortexRegistration.meanConfidence < 0.70 {
            issues.append(
                ReliabilityIssue(
                    severity: .warning,
                    title: "Low cortex geometry QC",
                    detail: "Mean cortex geometry QC is \(format(cortexRegistration.meanConfidence)); expected at least 0.70 before atlas registration."
                )
            )
        }

        if buildSummary.meanForegroundConfidence < 0.60 {
            issues.append(
                ReliabilityIssue(
                    severity: .warning,
                    title: "Weak foreground segmentation",
                    detail: "Mean split confidence is \(format(buildSummary.meanForegroundConfidence)); expected at least 0.60."
                )
            )
        }

        let lowConfidenceSlices = slices.filter {
            $0.registration.confidence < 0.55
                || $0.cortex.confidence < 0.55
                || $0.signal.foregroundConfidence < 0.45
        }
        if !lowConfidenceSlices.isEmpty {
            let examples = lowConfidenceSlices.prefix(4).map(\.title).joined(separator: ", ")
            issues.append(
                ReliabilityIssue(
                    severity: .warning,
                    title: "Low-confidence slices",
                    detail: "\(lowConfidenceSlices.count) slice(s) need review. Examples: \(examples)."
                )
            )
        }

        let emptyMasks = slices.filter { $0.signal.alphaCoverage <= 0 || $0.signal.tissueBounds.isEmpty }
        if !emptyMasks.isEmpty {
            issues.append(
                ReliabilityIssue(
                    severity: .failure,
                    title: "Empty tissue masks",
                    detail: "\(emptyMasks.count) slice(s) have no usable foreground mask."
                )
            )
        }

        let score = reliabilityScore(
            atlasRegistration: atlasRegistration,
            cortexRegistration: cortexRegistration,
            buildSummary: buildSummary,
            atlasReference: atlasReference,
            issues: issues
        )
        let level: ReliabilityLevel
        if issues.contains(where: { $0.severity == .failure }) || score < 0.62 {
            level = .unreliable
        } else if !atlasReference.isComplete || issues.contains(where: { $0.severity == .warning }) || score < 0.82 {
            level = .review
        } else {
            level = .needsAtlasRegistration
        }

        return ReliabilityReport(
            score: score,
            level: level,
            atlasReference: atlasReference,
            issues: issues
        )
    }

    private func reliabilityScore(
        atlasRegistration: AtlasRegistrationSummary,
        cortexRegistration: CortexRegistrationSummary,
        buildSummary: VolumeBuildSummary,
        atlasReference: AtlasReferenceVerification,
        issues: [ReliabilityIssue]
    ) -> Double {
        let referenceScore = atlasReference.isComplete ? 1.0 : Double(atlasReference.sizeMatchedFiles) / Double(max(1, atlasReference.expectedFiles))
        let signalScore = (
            atlasRegistration.meanConfidence * 0.24
            + atlasRegistration.meanContourScore * 0.20
            + cortexRegistration.meanConfidence * 0.20
            + cortexRegistration.meanSymmetry * 0.12
            + buildSummary.meanForegroundConfidence * 0.16
            + referenceScore * 0.08
        )
        let failurePenalty = Double(issues.filter { $0.severity == .failure }.count) * 0.18
        let warningPenalty = Double(issues.filter { $0.severity == .warning }.count) * 0.045
        return (signalScore - failurePenalty - warningPenalty).clamped(to: 0...1)
    }

    private func isMonotonic(_ values: [Double]) -> Bool {
        guard values.count > 1 else {
            return true
        }
        return zip(values, values.dropFirst()).allSatisfy { $0 <= $1 }
    }

    private func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

enum AtlasReferenceVerifier {
    static func verify(candidateFolders: [URL] = defaultCandidateFolders()) -> AtlasReferenceVerification {
        let resources = AllenAtlasCatalog.resources

        for folderURL in candidateFolders {
            let results = resources.map { resource -> (AllenAtlasResource, Bool, Bool, Int) in
                let fileURL = folderURL.appendingPathComponent(resource.filename)
                let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let exists = FileManager.default.fileExists(atPath: fileURL.path)
                let sizeMatches = exists && abs(size - resource.expectedBytes) <= max(1_024, resource.expectedBytes / 100)
                return (resource, exists, sizeMatches, size)
            }

            let present = results.filter { $0.1 }.count
            guard present > 0 else {
                continue
            }

            var issues: [ReliabilityIssue] = []
            for result in results where result.1 && !result.2 {
                issues.append(
                    ReliabilityIssue(
                        severity: .warning,
                        title: "Allen CCF file size mismatch",
                        detail: "\(result.0.filename) is \(result.3) bytes; expected about \(result.0.expectedBytes)."
                    )
                )
            }
            for result in results where !result.1 {
                issues.append(
                    ReliabilityIssue(
                        severity: .warning,
                        title: "Allen CCF file missing",
                        detail: result.0.filename
                    )
                )
            }

            return AtlasReferenceVerification(
                folderURL: folderURL,
                expectedFiles: resources.count,
                presentFiles: present,
                sizeMatchedFiles: results.filter { $0.2 }.count,
                issues: issues
            )
        }

        return AtlasReferenceVerification(
            folderURL: nil,
            expectedFiles: resources.count,
            presentFiles: 0,
            sizeMatchedFiles: 0,
            issues: [
                ReliabilityIssue(
                    severity: .warning,
                    title: "Allen CCF files missing",
                    detail: "Download the Allen CCF reference set before atlas registration or review."
                )
            ]
        )
    }

    private static func defaultCandidateFolders() -> [URL] {
        let candidates = [AllenAtlasCatalog.atlasInstallationURL]
        return candidates.reduce(into: []) { unique, url in
            if !unique.contains(url) {
                unique.append(url)
            }
        }
    }
}
