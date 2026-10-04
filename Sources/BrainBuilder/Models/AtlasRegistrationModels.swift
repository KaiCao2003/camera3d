import AppKit
import Foundation

enum AtlasOrientation: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case coronal
    case sagittal
    case horizontal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .coronal:
            "Coronal"
        case .sagittal:
            "Sagittal"
        case .horizontal:
            "Horizontal"
        }
    }
}

enum RegistrationChannelRole: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case structural
    case probeTrack
    case signal
    case ignored

    var id: String { rawValue }

    var title: String {
        switch self {
        case .structural:
            "Structural"
        case .probeTrack:
            "Probe track"
        case .signal:
            "Signal"
        case .ignored:
            "Ignored"
        }
    }
}

struct AtlasDescriptor: Codable, Hashable, Sendable {
    var id: String
    var version: String
    var name: String
    var voxelSizeMicrons: Double

    static let allenCCF2020 = AtlasDescriptor(
        id: "allen_mouse_25um",
        version: "1.2",
        name: "Allen Mouse CCFv3 (BrainGlobe)",
        voxelSizeMicrons: 25
    )
}

struct RegistrationChannelMapping: Codable, Identifiable, Hashable, Sendable {
    var id: Int { channelIndex }
    var channelIndex: Int
    var name: String
    var role: RegistrationChannelRole
    var pseudoColor: String?
}

enum SliceRegistrationStatus: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case unprepared
    case prepared
    case poseEstimated
    case affineDone
    case splineDone
    case needsReview
    case accepted
    case failed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unprepared:
            "Unprepared"
        case .prepared:
            "Prepared"
        case .poseEstimated:
            "Pose"
        case .affineDone:
            "Affine"
        case .splineDone:
            "Spline"
        case .needsReview:
            "Review"
        case .accepted:
            "Accepted"
        case .failed:
            "Failed"
        }
    }

    var isExportable: Bool {
        self == .accepted
    }

    var isReviewDecision: Bool {
        self == .accepted || self == .failed
    }
}

struct AtlasSlicingAngles: Codable, Hashable, Sendable {
    var pitchDegrees: Double
    var rollDegrees: Double
    var yawDegrees: Double

    static let zero = AtlasSlicingAngles(pitchDegrees: 0, rollDegrees: 0, yawDegrees: 0)
}

struct SlicePose: Codable, Hashable, Sendable {
    var atlasAPMicrons: Double
    var atlasSlicingAngles: AtlasSlicingAngles
    var rotationDegrees: Double
    var flipHorizontal: Bool
    var flipVertical: Bool
    var sourceConfidence: Double
    var manuallyLocked: Bool
    var provenance: String
    var atlasAnchoring: [Double]? = nil
    var predictionImageSize: PixelSize? = nil

    static func estimated(apMicrons: Double, confidence: Double, provenance: String) -> SlicePose {
        SlicePose(
            atlasAPMicrons: apMicrons,
            atlasSlicingAngles: .zero,
            rotationDegrees: 0,
            flipHorizontal: false,
            flipVertical: false,
            sourceConfidence: confidence.clamped(to: 0...1),
            manuallyLocked: false,
            provenance: provenance
        )
    }
}

enum TransformDirection: String, Codable, Hashable, Sendable {
    case atlasToSlice
    case sliceToAtlas

    var inverse: TransformDirection {
        switch self {
        case .atlasToSlice:
            .sliceToAtlas
        case .sliceToAtlas:
            .atlasToSlice
        }
    }
}

enum RegistrationTransformKind: String, Codable, Hashable, Sendable {
    case pose
    case affine
    case bspline
    case manualLandmarks
}

enum RegistrationStage: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case pose
    case affine
    case spline
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pose:
            "Pose"
        case .affine:
            "Affine"
        case .spline:
            "Spline"
        case .manual:
            "Manual"
        }
    }
}

struct AffineTransform2D: Codable, Hashable, Sendable {
    var m00: Double
    var m01: Double
    var m10: Double
    var m11: Double
    var tx: Double
    var ty: Double

    static let identity = AffineTransform2D(m00: 1, m01: 0, m10: 0, m11: 1, tx: 0, ty: 0)

    func applying(to point: RegistrationPoint) -> RegistrationPoint {
        RegistrationPoint(
            x: m00 * point.x + m01 * point.y + tx,
            y: m10 * point.x + m11 * point.y + ty
        )
    }

    func concatenating(_ next: AffineTransform2D) -> AffineTransform2D {
        AffineTransform2D(
            m00: next.m00 * m00 + next.m01 * m10,
            m01: next.m00 * m01 + next.m01 * m11,
            m10: next.m10 * m00 + next.m11 * m10,
            m11: next.m10 * m01 + next.m11 * m11,
            tx: next.m00 * tx + next.m01 * ty + next.tx,
            ty: next.m10 * tx + next.m11 * ty + next.ty
        )
    }

    func inverted() -> AffineTransform2D? {
        let determinant = m00 * m11 - m01 * m10
        guard abs(determinant) > 1e-12 else {
            return nil
        }

        let inverse00 = m11 / determinant
        let inverse01 = -m01 / determinant
        let inverse10 = -m10 / determinant
        let inverse11 = m00 / determinant
        return AffineTransform2D(
            m00: inverse00,
            m01: inverse01,
            m10: inverse10,
            m11: inverse11,
            tx: -(inverse00 * tx + inverse01 * ty),
            ty: -(inverse10 * tx + inverse11 * ty)
        )
    }
}

struct RegistrationPoint: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
}

struct RasterOrientation: Codable, Hashable, Sendable {
    var rotationDegrees: Int
    var flipHorizontal: Bool
    var flipVertical: Bool
}

struct ManualLandmarkPair: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var atlasPoint: RegistrationPoint
    var slicePoint: RegistrationPoint
    var label: String
}

struct RegistrationTransform: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var kind: RegistrationTransformKind
    var stage: RegistrationStage
    var direction: TransformDirection
    var engine: String
    var affine: AffineTransform2D?
    var transformParametersPath: String?
    var landmarks: [ManualLandmarkPair]
    var metric: Double?
    var createdAt: Date
    var provenance: String
    var coordinateUnit: String? = nil
    var movingImageSpace: String? = nil
    var rasterOrientation: RasterOrientation? = nil

    var isUsableAtlasToSliceAffine: Bool {
        guard kind == .affine,
              direction == .atlasToSlice,
              coordinateUnit == "micron",
              let affine,
              [affine.m00, affine.m01, affine.m10, affine.m11, affine.tx, affine.ty].allSatisfy(\.isFinite),
              abs(affine.m00 * affine.m11 - affine.m01 * affine.m10) > 1e-9,
              let transformParametersPath,
              let serialized = try? String(contentsOfFile: transformParametersPath, encoding: .utf8),
              serialized.utf8.count < 2_000_000,
              serialized.hasPrefix("#Insight Transform File V1.0"),
              serialized.contains("AffineTransform_double_2_2"),
              let parsed = Self.affineFromInsightTransform(serialized),
              Self.affinesMatch(affine, parsed) else {
            return false
        }
        return true
    }

    private static func affineFromInsightTransform(_ value: String) -> AffineTransform2D? {
        let lines = value.split(whereSeparator: \Character.isNewline)
        guard let parameterLine = lines.last(where: { $0.hasPrefix("Parameters:") }),
              let centerLine = lines.last(where: { $0.hasPrefix("FixedParameters:") }) else {
            return nil
        }
        let parameters = parameterLine
            .dropFirst("Parameters:".count)
            .split(whereSeparator: \Character.isWhitespace)
            .compactMap { Double($0) }
        let center = centerLine
            .dropFirst("FixedParameters:".count)
            .split(whereSeparator: \Character.isWhitespace)
            .compactMap { Double($0) }
        guard parameters.count >= 6, center.count >= 2 else { return nil }
        let m00 = parameters[0]
        let m01 = parameters[1]
        let m10 = parameters[2]
        let m11 = parameters[3]
        let tx = center[0] + parameters[4] - (m00 * center[0] + m01 * center[1])
        let ty = center[1] + parameters[5] - (m10 * center[0] + m11 * center[1])
        return AffineTransform2D(m00: m00, m01: m01, m10: m10, m11: m11, tx: tx, ty: ty)
    }

    private static func affinesMatch(_ lhs: AffineTransform2D, _ rhs: AffineTransform2D) -> Bool {
        zip(
            [lhs.m00, lhs.m01, lhs.m10, lhs.m11, lhs.tx, lhs.ty],
            [rhs.m00, rhs.m01, rhs.m10, rhs.m11, rhs.tx, rhs.ty]
        ).allSatisfy { left, right in
            abs(left - right) <= max(1e-4, abs(right) * 1e-7)
        }
    }

    static func posePrior(_ pose: SlicePose) -> RegistrationTransform {
        RegistrationTransform(
            id: "pose-prior",
            kind: .pose,
            stage: .pose,
            direction: .atlasToSlice,
            engine: "BrainBuilder pose prior",
            affine: .identity,
            transformParametersPath: nil,
            landmarks: [],
            metric: pose.sourceConfidence,
            createdAt: Date(),
            provenance: pose.provenance
        )
    }
}

struct RegistrationArtifacts: Codable, Hashable, Sendable {
    var preparedImagePath: String?
    var structuralImagePath: String?
    var probeChannelImagePath: String?
    var tissueMaskPath: String?
    var atlasReferencePath: String?
    var registeredImagePath: String?
    var overlayImagePath: String?
    var boundaryImagePath: String?
    var checkerboardImagePath: String?
    var differenceImagePath: String?
    var annotationImagePath: String?
    var transformPath: String?
    var trackMaskPath: String?
    var trackOverlayPath: String?
    var atlasAPIndex: Int?
    var sourceOverlayImagePath: String? = nil
    var rawStructuralImagePath: String? = nil
    var rawProbeChannelImagePath: String? = nil
    var rawSourceOverlayImagePath: String? = nil
    var selectionMaskPath: String? = nil
    var rawSelectionMaskPath: String? = nil
}

struct ProbeTrackPoint: Codable, Hashable, Sendable {
    var pointId: String? = nil
    var x: Double
    var y: Double
    var inlier: Bool?
}

struct AtlasTrackPoint: Codable, Hashable, Sendable {
    var slicePoint: RegistrationPoint
    var apMicrons: Double
    var dorsalVentralMicrons: Double
    var rightLeftMicrons: Double
    var uncertaintyMicrons: Double?
}

struct ProbeTrackDetection: Codable, Hashable, Sendable {
    var candidateId: String? = nil
    var candidateDigest: String? = nil
    var status: String
    var channelName: String
    var points: [ProbeTrackPoint]
    var atlasPoints: [AtlasTrackPoint]
    var lineStart: RegistrationPoint?
    var lineEnd: RegistrationPoint?
    var confidence: Double
    var rmseMicrons: Double?
    var reviewAccepted: Bool? = nil
    var autoQualified: Bool? = nil
    var dorsalEntryDistanceFraction: Double? = nil
    var provenance: String
    var blind: Bool? = nil
}

struct Brain3DSubjectRebindAudit: Codable, Hashable, Sendable {
    var auditId: String
    var planSubjectId: String
    var datasetSubjectId: String
    var datasetFingerprint: String
    var operatorLabel: String
    var reason: String
    var confirmedAt: Date
    var handoffSha256: String
}

struct Brain3DSubjectBinding: Codable, Hashable, Sendable {
    enum State: String, Codable, Hashable, Sendable {
        case exactMatch
        case explicitAliasRebind
    }

    var state: State
    var planSubjectId: String
    var datasetSubjectId: String
    var datasetFingerprint: String
    var rebindAudit: Brain3DSubjectRebindAudit? = nil
}

struct Brain3DPriorReceipt: Codable, Hashable, Sendable {
    var handoffId: String
    var handoffSha256: String
    var sourceProjectId: String
    var sourceProjectRevision: Int
    var sourceSubjectId: String
}

/// Read-only, digest-bound context imported from one immutable `.mouseplan`
/// handoff. The worker treats this as post-hoc overlay/review input only.
struct Brain3DContext: Codable, Hashable, Sendable {
    var handoff: Brain3DHistologyHandoff
    var priorReceipt: Brain3DPriorReceipt
    var subjectBinding: Brain3DSubjectBinding
    var blindReviewLocked: Bool
    var reviewDispositions: [Brain3DTrackDisposition] = []
    var reviewPreview: Brain3DReviewPreview? = nil

    /// A subject binding is valid only for the exact source-dataset identity
    /// that was present when the immutable handoff was selected.  Alias
    /// rebinds additionally retain the complete audited receipt.
    func isBound(toDatasetFingerprint currentFingerprint: String) -> Bool {
        guard !currentFingerprint.isEmpty,
              subjectBinding.datasetFingerprint == currentFingerprint else {
            return false
        }
        switch subjectBinding.state {
        case .exactMatch:
            return subjectBinding.planSubjectId == subjectBinding.datasetSubjectId
                && subjectBinding.rebindAudit == nil
        case .explicitAliasRebind:
            guard let audit = subjectBinding.rebindAudit else { return false }
            return audit.planSubjectId == subjectBinding.planSubjectId
                && audit.datasetSubjectId == subjectBinding.datasetSubjectId
                && audit.datasetFingerprint == currentFingerprint
                && audit.handoffSha256 == priorReceipt.handoffSha256
                && !audit.operatorLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !audit.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

struct Brain3DTrackDisposition: Codable, Identifiable, Hashable, Sendable {
    enum State: String, Codable, Hashable, Sendable {
        case exactShank
        case insertionLevelAmbiguous
        case observedUnmatched
        case plannedNotObserved
    }

    var id: String
    var state: State
    var trackId: String? = nil
    var insertionSnapshotId: String? = nil
    var shankId: String? = nil
    var reviewerLabel: String
    var reason: String
    var confirmedAt: Date
}

struct AtlasAssetPaths: Codable, Hashable, Sendable {
    var cachePath: String?
    var atlasRootPath: String?
    var atlasName: String?
    var atlasVersion: String?
    var orientation: String?
    var resolutionMicrons: [Double]?
    var fixturePath: String?
}

struct RegistrationProjectProvenance: Codable, Hashable, Sendable {
    var datasetFingerprint: String? = nil
    var workerVersion: String? = nil
    var poseEngine: String? = nil
    var deepSlicePredictionsPath: String? = nil
    var deepSliceOrientationCandidatesPath: String? = nil
    var deepSliceGroupOrientations: [String: Int]? = nil
    var deepSliceIndexOrderEnforced: Bool? = nil
    var deepSliceIndexOrderRecheckedAfterAngles: Bool? = nil
    var deepSliceBrainCenterOrderCorrected: Bool? = nil
    var deepSliceUpdatedSliceIDs: [String]? = nil
    var deepSliceFallbackReason: String? = nil
    var sourceImageHashes: [String: String]? = nil
    var selectionMaskHashes: [String: String]? = nil
}

struct TransformChain: Codable, Hashable, Sendable {
    var direction: TransformDirection
    var transforms: [RegistrationTransform]

    static let emptyAtlasToSlice = TransformChain(direction: .atlasToSlice, transforms: [])

    var hasQuantitativeTransform: Bool {
        transforms.contains { transform in
            transform.kind == .affine || transform.kind == .bspline || transform.kind == .manualLandmarks
        }
    }

    var hasUsableQuantitativeTransform: Bool {
        transforms.contains { $0.isUsableAtlasToSliceAffine }
    }

    var affineComposite: AffineTransform2D? {
        var composite = AffineTransform2D.identity
        for transform in transforms {
            guard let affine = transform.affine else {
                continue
            }
            composite = composite.concatenating(affine)
        }
        return composite
    }

    func invertedAffineComposite() -> AffineTransform2D? {
        affineComposite?.inverted()
    }
}

struct SliceRegistrationRecord: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var groupID: String
    var sourceImagePath: String
    var pixelSizeMicrons: Double?
    var imageSize: PixelSize
    var status: SliceRegistrationStatus
    var pose: SlicePose?
    var transformChain: TransformChain
    var qc: RegistrationQC
    var reviewNotes: String
    var artifacts: RegistrationArtifacts? = nil
    var probeTrack: ProbeTrackDetection? = nil
    var probeTrackCandidates: [ProbeTrackDetection]? = nil
    var canonicalRasterOrientation: RasterOrientation? = nil

    var effectiveProbeTrackCandidates: [ProbeTrackDetection] {
        if let probeTrackCandidates {
            return probeTrackCandidates
        }
        return probeTrack.map { [$0] } ?? []
    }

    var hasMaterializedRegistrationInput: Bool {
        guard status != .unprepared,
              let structuralImagePath = artifacts?.structuralImagePath,
              let rawStructuralPath = artifacts?.rawStructuralImagePath ?? artifacts?.structuralImagePath else {
            return false
        }
        let rawURL = URL(fileURLWithPath: rawStructuralPath).resolvingSymlinksInPath().standardizedFileURL
        let sourceURL = URL(fileURLWithPath: sourceImagePath).resolvingSymlinksInPath().standardizedFileURL
        return rawURL == sourceURL
            && FileManager.default.fileExists(atPath: rawStructuralPath)
            && FileManager.default.fileExists(atPath: structuralImagePath)
    }

    var hasWorkerEstimatedPose: Bool {
        transformChain.transforms.contains { transform in
            transform.kind == .pose && !transform.engine.hasPrefix("BrainBuilder pose prior")
        }
    }

    var hasUsableAtlasArtifacts: Bool {
        guard let annotation = artifacts?.annotationImagePath,
              let boundary = artifacts?.boundaryImagePath,
              let annotationSize = readableImagePixelSize(atPath: annotation),
              let boundarySize = readableImagePixelSize(atPath: boundary) else {
            return false
        }
        return annotationSize.width >= 16
            && annotationSize.height >= 16
            && annotationSize == boundarySize
    }

    var hasConsistentTransformArtifact: Bool {
        guard let artifactPath = artifacts?.transformPath,
              let transformPath = transformChain.transforms.last(where: {
                  $0.isUsableAtlasToSliceAffine
              })?.transformParametersPath else {
            return false
        }
        return URL(fileURLWithPath: artifactPath).resolvingSymlinksInPath().standardizedFileURL
            == URL(fileURLWithPath: transformPath).resolvingSymlinksInPath().standardizedFileURL
    }

    var isReadyForAcceptance: Bool {
        hasWorkerEstimatedPose
            && transformChain.hasUsableQuantitativeTransform
            && hasConsistentTransformArtifact
            && hasUsableAtlasArtifacts
    }
}

enum RegistrationProjectValidationError: LocalizedError, Equatable, Sendable {
    case tooManyProbeTrackCandidates(sliceID: String, count: Int, maximum: Int)

    var errorDescription: String? {
        switch self {
        case .tooManyProbeTrackCandidates(let sliceID, let count, let maximum):
            "Slice \(sliceID) contains \(count) blind probe-track candidates; "
                + "the schema limit is \(maximum)."
        }
    }
}

extension SliceRegistrationRecord {
    static let maximumProbeTrackCandidates = 32

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case groupID
        case sourceImagePath
        case pixelSizeMicrons
        case imageSize
        case status
        case pose
        case transformChain
        case qc
        case reviewNotes
        case artifacts
        case probeTrack
        case probeTrackCandidates
        case canonicalRasterOrientation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        groupID = try container.decode(String.self, forKey: .groupID)
        sourceImagePath = try container.decode(String.self, forKey: .sourceImagePath)
        pixelSizeMicrons = try container.decodeIfPresent(Double.self, forKey: .pixelSizeMicrons)
        imageSize = try container.decode(PixelSize.self, forKey: .imageSize)
        status = try container.decode(SliceRegistrationStatus.self, forKey: .status)
        pose = try container.decodeIfPresent(SlicePose.self, forKey: .pose)
        transformChain = try container.decode(TransformChain.self, forKey: .transformChain)
        qc = try container.decode(RegistrationQC.self, forKey: .qc)
        reviewNotes = try container.decode(String.self, forKey: .reviewNotes)
        artifacts = try container.decodeIfPresent(RegistrationArtifacts.self, forKey: .artifacts)
        probeTrack = try container.decodeIfPresent(ProbeTrackDetection.self, forKey: .probeTrack)
        probeTrackCandidates = try container.decodeIfPresent(
            [ProbeTrackDetection].self,
            forKey: .probeTrackCandidates
        )
        canonicalRasterOrientation = try container.decodeIfPresent(
            RasterOrientation.self,
            forKey: .canonicalRasterOrientation
        )
        if let count = probeTrackCandidates?.count,
           count > Self.maximumProbeTrackCandidates {
            throw DecodingError.dataCorruptedError(
                forKey: .probeTrackCandidates,
                in: container,
                debugDescription: RegistrationProjectValidationError
                    .tooManyProbeTrackCandidates(
                        sliceID: id,
                        count: count,
                        maximum: Self.maximumProbeTrackCandidates
                    )
                    .localizedDescription
            )
        }
    }

    func validateProbeTrackCandidateCapacity() throws {
        let count = effectiveProbeTrackCandidates.count
        guard count <= Self.maximumProbeTrackCandidates else {
            throw RegistrationProjectValidationError.tooManyProbeTrackCandidates(
                sliceID: id,
                count: count,
                maximum: Self.maximumProbeTrackCandidates
            )
        }
    }
}

struct RegistrationQC: Codable, Hashable, Sendable {
    var landmarkRMSErrorMicrons: Double?
    var majorRegionIoU: Double?
    var mutualInformationMetric: Double?
    var foregroundCoverage: Double?
    var warnings: [String]
    var rawPoseAPMicrons: Double? = nil
    var orderedPoseAPMicrons: Double? = nil
    var poseAdjustmentMicrons: Double? = nil

    static let empty = RegistrationQC(
        landmarkRMSErrorMicrons: nil,
        majorRegionIoU: nil,
        mutualInformationMetric: nil,
        foregroundCoverage: nil,
        warnings: []
    )
}

struct RegistrationProject: Codable, Identifiable, Hashable, Sendable {
    var schemaVersion: Int? = 2
    var id: String
    var subjectID: String? = nil
    var datasetRootPath: String
    var atlas: AtlasDescriptor
    var orientation: AtlasOrientation
    var pixelSizeMicrons: Double?
    var channelMappings: [RegistrationChannelMapping]
    var slices: [SliceRegistrationRecord]
    var createdAt: Date
    var updatedAt: Date
    var atlasAssets: AtlasAssetPaths? = nil
    var sourceMode: StackSourceMode
    var provenance: RegistrationProjectProvenance? = nil
    var brain3dContext: Brain3DContext? = nil
    var colonySubjectReceipt: ColonySubjectReceipt? = nil
    var blindReviewLocked: Bool = false
    var blindTrackReview: BlindTrackReviewState? = nil
    var blindTrackReviewPreview: BlindTrackReviewPreview? = nil

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, subjectID, datasetRootPath, atlas, orientation
        case pixelSizeMicrons, channelMappings, slices, createdAt, updatedAt
        case atlasAssets, sourceMode, provenance, brain3dContext, colonySubjectReceipt
        case blindReviewLocked, blindTrackReview, blindTrackReviewPreview
    }

    mutating func migrateToCurrentSchema() {
        for index in slices.indices where slices[index].probeTrackCandidates == nil {
            slices[index].probeTrackCandidates = slices[index].probeTrack.map { [$0] } ?? []
        }
        schemaVersion = 2
    }

    func validateProbeTrackCandidateCapacity() throws {
        for slice in slices {
            try slice.validateProbeTrackCandidateCapacity()
        }
    }

    var acceptedSlices: [SliceRegistrationRecord] {
        slices.filter { $0.status.isExportable }
    }

    var reviewedSlices: [SliceRegistrationRecord] {
        slices.filter { $0.status.isReviewDecision }
    }

    var pendingReviewSlices: [SliceRegistrationRecord] {
        slices.filter { !$0.status.isReviewDecision }
    }

    func nextPendingReviewSliceID(after currentID: String?) -> String? {
        guard !slices.isEmpty else { return nil }
        guard let currentIndex = currentID.flatMap({ id in
            slices.firstIndex { $0.id == id }
        }) else {
            return pendingReviewSlices.first?.id
        }

        let following = slices.index(after: currentIndex)..<slices.endIndex
        if let next = following.first(where: { !slices[$0].status.isReviewDecision }) {
            return slices[next].id
        }

        let preceding = slices.startIndex..<currentIndex
        if let next = preceding.first(where: { !slices[$0].status.isReviewDecision }) {
            return slices[next].id
        }

        return nil
    }

    var structuralChannels: [RegistrationChannelMapping] {
        channelMappings.filter { $0.role == .structural }
    }

    /// `SlicePose.estimated` is also used for the Swift-only ordering prior, so
    /// neither a non-nil pose nor a 0-degree rotation is evidence that a
    /// montage raster is in canonical orientation.  Canonical section views
    /// may only publish a project after the complete DeepSlice batch contract
    /// below has been returned by the worker.
    var hasCompleteCanonicalSectionOrientation: Bool {
        guard sourceMode == .montageSections,
              !slices.isEmpty,
              let provenance,
              provenance.datasetFingerprint?.isEmpty == false,
              provenance.deepSliceFallbackReason == nil,
              provenance.poseEngine?.lowercased().hasPrefix("deepslice") == true,
              provenance.deepSlicePredictionsPath?.isEmpty == false,
              provenance.deepSliceOrientationCandidatesPath?.isEmpty == false,
              let groupOrientations = provenance.deepSliceGroupOrientations,
              let updatedSliceIDs = provenance.deepSliceUpdatedSliceIDs,
              let sourceImageHashes = provenance.sourceImageHashes else {
            return false
        }

        if slices.count > 1 {
            guard provenance.deepSliceIndexOrderEnforced == true,
                  provenance.deepSliceIndexOrderRecheckedAfterAngles == true,
                  provenance.deepSliceBrainCenterOrderCorrected == true else {
                return false
            }
            let apValues = slices.compactMap { $0.pose?.atlasAPMicrons }
            guard apValues.count == slices.count,
                  let firstAP = apValues.first,
                  let lastAP = apValues.last,
                  abs(lastAP - firstAP) > 1e-6 else {
                return false
            }
            let differences = zip(apValues.dropFirst(), apValues).map { current, previous in
                current - previous
            }
            let nondecreasing = differences.allSatisfy { $0 >= -1e-6 }
            let nonincreasing = differences.allSatisfy { $0 <= 1e-6 }
            // A reviewed manual AP correction can intentionally override the
            // estimated serial order without changing raster orientation.
            guard nondecreasing || nonincreasing || slices.contains(where: { $0.pose?.manuallyLocked == true }) else {
                return false
            }
        }

        let sliceIDs = Set(slices.map(\.id))
        if let selectionMaskHashes = provenance.selectionMaskHashes,
           !sliceIDs.isSubset(of: Set(selectionMaskHashes.keys)) {
            return false
        }
        let workerUpdatedSliceIDs = Set(
            slices.filter {
                $0.pose?.manuallyLocked != true
                    && $0.pose?.provenance != "Unlocked by reviewer"
            }.map(\.id)
        )
        let groupIDs = Set(slices.map(\.groupID))
        guard sliceIDs.count == slices.count,
              workerUpdatedSliceIDs.isSubset(of: Set(updatedSliceIDs)),
              sliceIDs.isSubset(of: Set(sourceImageHashes.keys)),
              groupIDs.isSubset(of: Set(groupOrientations.keys)),
              groupIDs.allSatisfy({ groupOrientations[$0] == 0 || groupOrientations[$0] == 180 }) else {
            return false
        }

        return slices.allSatisfy { slice in
            guard slice.hasWorkerEstimatedPose,
                  let pose = slice.pose,
                  pose.atlasAPMicrons.isFinite,
                  pose.sourceConfidence.isFinite,
                  pose.atlasSlicingAngles.pitchDegrees.isFinite,
                  pose.atlasSlicingAngles.rollDegrees.isFinite,
                  pose.atlasSlicingAngles.yawDegrees.isFinite,
                  pose.atlasAnchoring?.count == 9,
                  pose.atlasAnchoring?.allSatisfy(\.isFinite) == true,
                  let predictionImageSize = pose.predictionImageSize,
                  predictionImageSize.width > 0,
                  predictionImageSize.height > 0,
                  !pose.flipHorizontal,
                  !pose.flipVertical,
                  let rotation = Self.canonicalRotation(pose.rotationDegrees),
                  let workerTransform = slice.transformChain.transforms.last(where: {
                      $0.kind == .pose && !$0.engine.hasPrefix("BrainBuilder pose prior")
                  }) else {
                return false
            }

            // A reviewer may deliberately override a completed DeepSlice pose.
            // The lock is explicit evidence; its supported 0/180 orientation is
            // then authoritative until affine registration is rerun.
            if pose.manuallyLocked {
                return (workerTransform.engine.lowercased().hasPrefix("deepslice")
                    || workerTransform.engine.hasPrefix("Manual QuickNII plane correction "))
                    && (rotation == 0 || rotation == 180)
            }

            guard workerTransform.engine.lowercased().hasPrefix("deepslice"),
                  let transformOrientation = workerTransform.rasterOrientation,
                  !transformOrientation.flipHorizontal,
                  !transformOrientation.flipVertical,
                  transformOrientation.rotationDegrees == rotation else {
                return false
            }
            return groupOrientations[slice.groupID] == rotation
                || pose.provenance == "Unlocked by reviewer"
        }
    }

    /// Safe automatic recovery is limited to a project that contains no
    /// worker pose, review decision, manual edit, or downstream registration.
    /// This includes an interrupted Prepare run, which can be materialized
    /// again from the immutable in-memory source volume.
    var canAutomaticallyEstimateInitialSectionOrientation: Bool {
        guard sourceMode == .montageSections,
              !slices.isEmpty,
              Set(slices.map(\.id)).count == slices.count,
              provenance?.poseEngine == nil,
              provenance?.deepSliceFallbackReason == nil,
              provenance?.deepSliceGroupOrientations == nil,
              slices.allSatisfy({ slice in
                  (slice.status == .unprepared || slice.status == .prepared)
                      && !slice.hasWorkerEstimatedPose
                      && !slice.transformChain.hasQuantitativeTransform
                      && !slice.transformChain.transforms.isEmpty
                      && slice.transformChain.transforms.allSatisfy {
                          $0.kind == .pose && $0.engine.hasPrefix("BrainBuilder pose prior")
                      }
                      && slice.pose?.manuallyLocked != true
                      && slice.probeTrack == nil
                      && slice.reviewNotes.isEmpty
                      && !slice.status.isReviewDecision
              }) else {
            return false
        }
        return true
    }

    private static func canonicalRotation(_ degrees: Double) -> Int? {
        guard degrees.isFinite else { return nil }
        let rounded = Int(degrees.rounded())
        guard abs(degrees - Double(rounded)) < 0.001 else { return nil }
        let normalized = ((rounded % 360) + 360) % 360
        return normalized == 0 || normalized == 180 ? normalized : nil
    }

    var blockersForAtlasExport: [String] {
        var blockers: [String] = []
        let candidateOverflow = slices.filter {
            $0.effectiveProbeTrackCandidates.count
                > SliceRegistrationRecord.maximumProbeTrackCandidates
        }
        if !candidateOverflow.isEmpty {
            blockers.append(
                "\(candidateOverflow.count) slice(s) exceed the "
                    + "\(SliceRegistrationRecord.maximumProbeTrackCandidates)-candidate blind track limit."
            )
        }
        if let pixelSizeMicrons {
            if !(0.1...100).contains(pixelSizeMicrons) {
                blockers.append("Physical pixel size calibration is implausible (expected 0.1-100 um/px).")
            }
        } else {
            blockers.append("Missing physical pixel size calibration.")
        }
        if structuralChannels.isEmpty {
            blockers.append("No structural registration channel selected.")
        } else if structuralChannels.count > 1 {
            blockers.append("Select exactly one structural registration channel.")
        }
        let invalidSliceCalibration = slices.filter { slice in
            guard let value = slice.pixelSizeMicrons else { return true }
            return !(0.1...100).contains(value)
        }
        if !invalidSliceCalibration.isEmpty {
            blockers.append("\(invalidSliceCalibration.count) slice(s) are missing a valid per-section pixel calibration.")
        }
        if orientation != .coronal {
            blockers.append("V1 supports only adult mouse coronal sections.")
        }
        if sourceMode != .montageSections {
            blockers.append("A verified montage-section source is required; numbered or legacy unknown inputs cannot be exported.")
        }
        if atlas.id != AtlasDescriptor.allenCCF2020.id || atlas.version != AtlasDescriptor.allenCCF2020.version {
            blockers.append("Atlas must be BrainGlobe Allen Mouse CCFv3 25um v1.2.")
        }
        if slices.isEmpty {
            blockers.append("Registration project has no tissue sections.")
        }
        let unaccepted = slices.filter { !$0.status.isExportable }
        if !unaccepted.isEmpty {
            blockers.append("\(unaccepted.count) slice(s) are not accepted after review.")
        }
        let missingTransforms = acceptedSlices.filter {
            !$0.transformChain.hasUsableQuantitativeTransform || !$0.hasConsistentTransformArtifact
        }
        if !missingTransforms.isEmpty {
            blockers.append("\(missingTransforms.count) accepted slice(s) do not have a usable on-disk atlas-to-slice affine transform.")
        }
        let missingArtifacts = acceptedSlices.filter { !$0.hasUsableAtlasArtifacts }
        if !missingArtifacts.isEmpty {
            blockers.append("\(missingArtifacts.count) accepted slice(s) are missing atlas annotation/boundary artifacts.")
        }
        if let brain3dContext {
            blockers.append(contentsOf: brain3dContext.manualReviewBlockers)
        }
        return blockers
    }
}

struct RegistrationCompletionStatusCounts: Hashable, Sendable {
    var affineDone: Int
    var needsReview: Int
    var accepted: Int
    var failed: Int

    var total: Int {
        affineDone + needsReview + accepted + failed
    }
}

struct MontageSliceOrientation: Hashable, Sendable {
    var rotationDegrees: Double
    var flipHorizontal: Bool
    var flipVertical: Bool

    init?(pose: SlicePose?) {
        guard let pose, pose.rotationDegrees.isFinite else {
            return nil
        }
        let remainder = pose.rotationDegrees.truncatingRemainder(dividingBy: 360)
        let normalized = remainder < 0 ? remainder + 360 : remainder
        let quantized = (normalized * 1_000).rounded() / 1_000
        rotationDegrees = quantized == 360 ? 0 : quantized
        flipHorizontal = pose.flipHorizontal
        flipVertical = pose.flipVertical
    }

    var title: String {
        var components = [Self.formattedDegrees(rotationDegrees)]
        if flipHorizontal {
            components.append("flip H")
        }
        if flipVertical {
            components.append("flip V")
        }
        return components.joined(separator: " · ")
    }

    var accessibilityTitle: String {
        var components = [Self.formattedDegrees(rotationDegrees)]
        if flipHorizontal {
            components.append("horizontal flip")
        }
        if flipVertical {
            components.append("vertical flip")
        }
        return components.joined(separator: ", ")
    }

    fileprivate static func ordered(_ lhs: MontageSliceOrientation, _ rhs: MontageSliceOrientation) -> Bool {
        if lhs.rotationDegrees != rhs.rotationDegrees {
            return lhs.rotationDegrees < rhs.rotationDegrees
        }
        if lhs.flipHorizontal != rhs.flipHorizontal {
            return !lhs.flipHorizontal
        }
        return !lhs.flipVertical && rhs.flipVertical
    }

    private static func formattedDegrees(_ value: Double) -> String {
        var formatted = String(format: "%.3f", value)
        while formatted.last == "0" {
            formatted.removeLast()
        }
        if formatted.last == "." {
            formatted.removeLast()
        }
        return "\(formatted)°"
    }
}

enum MontageGroupOrientationState: Hashable, Sendable {
    case consistent(MontageSliceOrientation)
    case incomplete(orientation: MontageSliceOrientation?, orientedCount: Int, total: Int)
    case inconsistent(orientations: [MontageSliceOrientation], missingCount: Int, total: Int)

    var isConsistent: Bool {
        if case .consistent = self {
            return true
        }
        return false
    }

    var title: String {
        switch self {
        case .consistent(let orientation):
            return orientation.title
        case .incomplete(let orientation, let orientedCount, let total):
            if let orientation {
                return "Incomplete · \(orientedCount)/\(total) at \(orientation.title)"
            } else {
                return "Missing · 0/\(total)"
            }
        case .inconsistent(let orientations, let missingCount, _):
            let values = orientations.map(\.title).joined(separator: ", ")
            if missingCount > 0 {
                return "Inconsistent · \(values) · \(missingCount) missing"
            } else {
                return "Inconsistent · \(values)"
            }
        }
    }

    var accessibilityTitle: String {
        switch self {
        case .consistent(let orientation):
            return orientation.accessibilityTitle
        case .incomplete(let orientation, let orientedCount, let total):
            if let orientation {
                return "incomplete, \(orientedCount) of \(total) sections at \(orientation.accessibilityTitle)"
            } else {
                return "missing orientation for all \(total) sections"
            }
        case .inconsistent(let orientations, let missingCount, _):
            var value = "inconsistent, " + orientations.map(\.accessibilityTitle).joined(separator: ", ")
            if missingCount > 0 {
                value += ", \(missingCount) missing"
            }
            return value
        }
    }
}

struct MontageGroupOrientationSummary: Identifiable, Hashable, Sendable {
    var id: String { groupID }
    var groupID: String
    var state: MontageGroupOrientationState

    var displayGroupID: String {
        groupID.isEmpty ? "Unnamed group" : groupID
    }
}

struct RegistrationCompletionSummary: Hashable, Sendable {
    var statusCounts: RegistrationCompletionStatusCounts
    var medianMajorRegionIoU: Double?
    var p10MajorRegionIoU: Double?
    var measuredMajorRegionIoUCount: Int
    var missingMajorRegionIoUCount: Int
    var invalidMajorRegionIoUCount: Int
    var groupOrientations: [MontageGroupOrientationSummary]

    init?(project: RegistrationProject) {
        let completedStatuses: Set<SliceRegistrationStatus> = [
            .affineDone,
            .needsReview,
            .accepted,
            .failed
        ]
        guard !project.slices.isEmpty,
              project.slices.allSatisfy({ completedStatuses.contains($0.status) }) else {
            return nil
        }

        statusCounts = RegistrationCompletionStatusCounts(
            affineDone: project.slices.filter { $0.status == .affineDone }.count,
            needsReview: project.slices.filter { $0.status == .needsReview }.count,
            accepted: project.slices.filter { $0.status == .accepted }.count,
            failed: project.slices.filter { $0.status == .failed }.count
        )

        let reportedIoU = project.slices.compactMap { $0.qc.majorRegionIoU }
        let validIoU = reportedIoU
            .filter { $0.isFinite && (0...1).contains($0) }
            .sorted()
        measuredMajorRegionIoUCount = validIoU.count
        missingMajorRegionIoUCount = project.slices.count - reportedIoU.count
        invalidMajorRegionIoUCount = reportedIoU.count - validIoU.count
        medianMajorRegionIoU = Self.percentile(0.5, in: validIoU)
        p10MajorRegionIoU = Self.percentile(0.1, in: validIoU)

        groupOrientations = Dictionary(grouping: project.slices, by: \.groupID)
            .map { groupID, slices in
                let orientations = slices.compactMap { MontageSliceOrientation(pose: $0.pose) }
                let unique = Array(Set(orientations)).sorted(by: MontageSliceOrientation.ordered)
                let missingCount = slices.count - orientations.count
                let state: MontageGroupOrientationState
                if missingCount == 0, let orientation = unique.first, unique.count == 1 {
                    state = .consistent(orientation)
                } else if unique.count <= 1 {
                    state = .incomplete(
                        orientation: unique.first,
                        orientedCount: orientations.count,
                        total: slices.count
                    )
                } else {
                    state = .inconsistent(
                        orientations: unique,
                        missingCount: missingCount,
                        total: slices.count
                    )
                }
                return MontageGroupOrientationSummary(groupID: groupID, state: state)
            }
            .sorted {
                $0.displayGroupID.localizedStandardCompare($1.displayGroupID) == .orderedAscending
            }
    }

    private static func percentile(_ percentile: Double, in sortedValues: [Double]) -> Double? {
        guard let first = sortedValues.first else {
            return nil
        }
        guard sortedValues.count > 1 else {
            return first
        }
        let position = percentile.clamped(to: 0...1) * Double(sortedValues.count - 1)
        let lowerIndex = Int(position.rounded(.down))
        let upperIndex = Int(position.rounded(.up))
        guard lowerIndex != upperIndex else {
            return sortedValues[lowerIndex]
        }
        let fraction = position - Double(lowerIndex)
        return sortedValues[lowerIndex]
            + (sortedValues[upperIndex] - sortedValues[lowerIndex]) * fraction
    }
}

private func readableImagePixelSize(atPath path: String) -> PixelSize? {
    guard let image = NSImage(contentsOfFile: path) else { return nil }
    var rect = NSRect(origin: .zero, size: image.size)
    guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
        return nil
    }
    return PixelSize(width: cgImage.width, height: cgImage.height)
}

struct AtlasExport: Codable, Hashable, Sendable {
    var schemaVersion: Int? = 2
    var projectID: String
    var atlas: AtlasDescriptor
    var exportedAt: Date
    var outputFolderPath: String
    var sliceExports: [SliceAtlasExport]
    var provenance: RegistrationProvenance
    var probeTrackPath: String? = nil
    var probeTracksPath: String? = nil
    var brain3dReviewPath: String? = nil
    var siteAssignmentsPath: String? = nil
    var priorReceipt: Brain3DPriorReceipt? = nil
    var colonySubjectReceipt: ColonySubjectReceipt? = nil
    var blindOutputs: BlindOutputDigests? = nil
    var manifestSha256: String? = nil
}

extension RegistrationProject {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard (1...2).contains(version) else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: values,
                debugDescription: "Unsupported registration project schema \(version); expected 1 or 2."
            )
        }
        schemaVersion = version
        id = try values.decode(String.self, forKey: .id)
        subjectID = try values.decodeIfPresent(String.self, forKey: .subjectID)
        datasetRootPath = try values.decode(String.self, forKey: .datasetRootPath)
        atlas = try values.decode(AtlasDescriptor.self, forKey: .atlas)
        orientation = try values.decode(AtlasOrientation.self, forKey: .orientation)
        pixelSizeMicrons = try values.decodeIfPresent(Double.self, forKey: .pixelSizeMicrons)
        channelMappings = try values.decode([RegistrationChannelMapping].self, forKey: .channelMappings)
        slices = try values.decode([SliceRegistrationRecord].self, forKey: .slices)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        atlasAssets = try values.decodeIfPresent(AtlasAssetPaths.self, forKey: .atlasAssets)
        sourceMode = try values.decode(StackSourceMode.self, forKey: .sourceMode)
        provenance = try values.decodeIfPresent(RegistrationProjectProvenance.self, forKey: .provenance)
        brain3dContext = try values.decodeIfPresent(Brain3DContext.self, forKey: .brain3dContext)
        colonySubjectReceipt = try values.decodeIfPresent(ColonySubjectReceipt.self, forKey: .colonySubjectReceipt)
        // Saved projects predating blind review remain unlocked until explicitly reviewed.
        blindReviewLocked = try values.decodeIfPresent(Bool.self, forKey: .blindReviewLocked) ?? false
        blindTrackReview = try values.decodeIfPresent(BlindTrackReviewState.self, forKey: .blindTrackReview)
        blindTrackReviewPreview = try values.decodeIfPresent(BlindTrackReviewPreview.self, forKey: .blindTrackReviewPreview)
    }
}

struct BlindOutputDigests: Codable, Hashable, Sendable {
    var runId: String
    var policy: String
    var registrationInputSha256: String
    var deepSliceOutputSha256: String
    var affineOutputSha256: String
    var trackCandidateOutputSha256: String
    var reviewedTrackSetSha256: String?
}

struct SliceAtlasExport: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var atlasCoordinateImagePath: String?
    var regionOutlinesPath: String?
    var transformChainPath: String
    var qc: RegistrationQC
    var probeTrack: ProbeTrackDetection? = nil
}

struct RegistrationProvenance: Codable, Hashable, Sendable {
    var appVersion: String
    var atlasChecksum: String?
    var engineVersions: [String: String]
    var sourceImageHashes: [String: String]
    var parameterFiles: [String]
}
