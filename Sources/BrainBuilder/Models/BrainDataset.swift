import AppKit
import Foundation

struct BrainDataset: Identifiable {
    let id = UUID()
    let rootURL: URL
    var groups: [BrainGroup]

    var totalSlices: Int {
        groups.reduce(0) { $0 + $1.slices.count }
    }

    var montageCount: Int {
        groups.filter { $0.montageOverlayURL != nil }.count
    }

    var allNumberedOverlaySlices: [BrainSlice] {
        groups.flatMap { group in
            group.slices.filter { $0.overlayURL != nil }
        }
        .sorted()
    }
}

struct BrainGroup: Identifiable, Hashable {
    let id: String
    var folderURL: URL
    var metadata: MicroscopeMetadata
    var slices: [BrainSlice]
    var montageOverlayURL: URL?
    var montageChannel2URL: URL?
    var montageChannel3URL: URL?

    var title: String { id }
}

struct BrainSlice: Identifiable, Hashable, Comparable {
    var id: String
    var groupID: String
    var index: Int
    var overlayURL: URL?
    var channel2URL: URL?
    var channel3URL: URL?
    var isMontage: Bool

    static func < (lhs: BrainSlice, rhs: BrainSlice) -> Bool {
        if lhs.groupID != rhs.groupID {
            return lhs.groupID < rhs.groupID
        }
        return lhs.index < rhs.index
    }
}

enum StackSourceMode: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case montageSections
    case numberedOverlays

    var id: String { rawValue }

    var title: String {
        switch self {
        case .montageSections:
            "Detected section montage"
        case .numberedOverlays:
            "Numbered acquisition tiles (preview only)"
        }
    }

    var shortTitle: String {
        switch self {
        case .montageSections:
            "Sections"
        case .numberedOverlays:
            "Tile preview"
        }
    }

    var detail: String {
        switch self {
        case .montageSections:
            "Segment large tissue sections from Untitled overlay images."
        case .numberedOverlays:
            "Preview overlapping acquisition tiles. These are not treated as serial histology sections for atlas registration."
        }
    }
}

enum WorkspaceViewMode: String, CaseIterable, Identifiable {
    case reconstruct
    case split
    case register
    case export

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reconstruct:
            "3D"
        case .split:
            "Split"
        case .register:
            "Atlas"
        case .export:
            "Export"
        }
    }

    var showsMetadataInspector: Bool {
        switch self {
        case .reconstruct, .split:
            true
        case .register, .export:
            false
        }
    }

    var showsDatasetSidebar: Bool {
        switch self {
        case .reconstruct, .split:
            true
        case .register, .export:
            false
        }
    }
}

struct BrainVolume: Identifiable {
    let id = UUID()
    var revision = UUID()
    var sourceMode: StackSourceMode
    var slices: [VolumeSlice]
    var bounds: SIMD3<Double>
    var atlasRegistration: AtlasRegistrationSummary
    var cortexRegistration: CortexRegistrationSummary
    var buildSummary: VolumeBuildSummary
    var reliabilityReport: ReliabilityReport
}

struct VolumeSlice: Identifiable {
    let id: String
    var title: String
    var sourceURL: URL
    var groupID: String
    var texture: NSImage
    var width: Double
    var height: Double
    var z: Double
    var offsetX: Double
    var offsetY: Double
    var opacity: Double
    var signal: SliceSignal
    var registration: SliceRegistration
    var cortex: CortexRegistration
    var channelImages: [VolumeChannelImage] = []
    var sourcePixelScale: Double = 1
    var nativeCropRect: CGRect? = nil
    /// Calibrated size of the extracted section. Keeping this separate from
    /// scene units prevents registration previews from normalizing away the
    /// real rostro-caudal taper of the brain.
    var physicalWidthMicrons: Double? = nil
    var physicalHeightMicrons: Double? = nil
    /// Orientation currently applied to `texture` and `channelImages`.
    var rotationDegrees: Double = 0
    /// Quantitative placement of canonical slice pixels into Allen atlas space.
    /// This remains nil until a real on-disk affine transform is available.
    var atlasPlacement: AtlasSlicePlacement? = nil
}

/// Maps a canonical, oriented section pixel through the reviewed 2D affine and
/// DeepSlice/BrainGlobe plane basis into the shared 3D scene coordinate system.
struct AtlasSlicePlacement {
    var sliceToAtlasPlane: AffineTransform2D
    var pixelSizeMicrons: Double
    var planeSize: PixelSize
    /// BrainGlobe ASR array-index basis: AP, superior-inferior, right-left.
    var atlasOriginIndex: SIMD3<Double>
    var atlasUIndex: SIMD3<Double>
    var atlasVIndex: SIMD3<Double>
    var atlasResolutionMicrons: SIMD3<Double>
    var atlasCenterMicrons: SIMD3<Double>
    var sceneMicronsPerUnit: Double
    var isReviewed: Bool

    func scenePoint(pixelX: Double, pixelY: Double) -> SIMD3<Float>? {
        guard pixelSizeMicrons.isFinite, pixelSizeMicrons > 0,
              sceneMicronsPerUnit.isFinite, sceneMicronsPerUnit > 0,
              planeSize.width > 0, planeSize.height > 0 else {
            return nil
        }
        let atlasPlanePoint = sliceToAtlasPlane.applying(
            to: RegistrationPoint(
                x: pixelX * pixelSizeMicrons,
                y: pixelY * pixelSizeMicrons
            )
        )
        let xFraction = atlasPlanePoint.x / (Double(planeSize.width) * pixelSizeMicrons)
        let yFraction = atlasPlanePoint.y / (Double(planeSize.height) * pixelSizeMicrons)
        let atlasIndex = atlasOriginIndex + atlasUIndex * xFraction + atlasVIndex * yFraction
        let atlasMicrons = atlasIndex * atlasResolutionMicrons

        return AtlasSceneGeometry.scenePoint(
            atlasASRMicrons: atlasMicrons,
            atlasCenterMicrons: atlasCenterMicrons,
            sceneMicronsPerUnit: sceneMicronsPerUnit
        )
    }
}

struct VolumeChannelImage: Identifiable {
    var id: Int { channelIndex }
    var channelIndex: Int
    var name: String
    var pseudoColor: String?
    var sourceURL: URL
    var texture: NSImage
    var sourcePixelScale: Double = 1
    /// These masks stay in the original channel crop grid when texture rotates.
    var registrationSelectionMask: NSImage? = nil
    var registrationSeedMask: NSImage? = nil
}

struct SliceSignal: Hashable {
    var redMean: Double
    var greenMean: Double
    var blueMean: Double
    var alphaCoverage: Double
    var tissueBounds: CGRect
    var imageSize: PixelSize
    var componentAreaPixels: Int
    var componentBounds: CGRect
    var foregroundConfidence: Double
    var backgroundSuppression: Double
}

extension SliceSignal {
    var componentFillRatio: Double {
        let boundsArea = max(1, componentBounds.width * componentBounds.height)
        return (Double(componentAreaPixels) / Double(boundsArea)).clamped(to: 0...1)
    }

    var touchesLateralCropEdge: Bool {
        let imageWidth = CGFloat(max(1, imageSize.width))
        return componentBounds.minX <= 1 || componentBounds.maxX >= imageWidth - 1
    }

    var sectionReviewFlags: [String] {
        var flags: [String] = []
        if touchesLateralCropEdge {
            flags.append("Side edge")
        }
        if componentFillRatio < 0.62 {
            flags.append("Low fill")
        }
        if foregroundConfidence < 0.70 {
            flags.append("Low confidence")
        }
        return flags
    }
}

struct VolumeBuildSummary: Hashable {
    var sourceImages: Int
    var producedSlices: Int
    var rejectedComponents: Int
    var maxTexturePixels: Int
    var meanForegroundConfidence: Double
    var meanBackgroundRemoved: Double
}

struct SliceRegistration: Hashable {
    var orderIndex: Int
    var atlasAPMicrons: Double
    var atlasAPIndex10um: Int
    var atlasScale: Double
    var atlasOffsetX: Double
    var atlasOffsetY: Double
    var confidence: Double
    var atlasContourScore: Double
    var atlasContourDeviation: Double
    var method: String

    static let unregistered = SliceRegistration(
        orderIndex: 0,
        atlasAPMicrons: 0,
        atlasAPIndex10um: 0,
        atlasScale: 1,
        atlasOffsetX: 0,
        atlasOffsetY: 0,
        confidence: 0,
        atlasContourScore: 0,
        atlasContourDeviation: 0,
        method: "unregistered"
    )
}

struct CortexRegistration: Hashable {
    var midlineX: Double
    var dorsalY: Double
    var leftCortexX: Double
    var rightCortexX: Double
    var cortexWidth: Double
    var symmetryScore: Double
    var confidence: Double
    var method: String

    static let unregistered = CortexRegistration(
        midlineX: 0,
        dorsalY: 0,
        leftCortexX: 0,
        rightCortexX: 0,
        cortexWidth: 0,
        symmetryScore: 0,
        confidence: 0,
        method: "unregistered"
    )
}

struct CortexRegistrationSummary: Hashable {
    var method: String
    var sliceCount: Int
    var meanConfidence: Double
    var meanSymmetry: Double
    var medianCortexWidth: Double

    static let empty = CortexRegistrationSummary(
        method: "none",
        sliceCount: 0,
        meanConfidence: 0,
        meanSymmetry: 0,
        medianCortexWidth: 0
    )
}

struct AtlasRegistrationSummary: Hashable {
    var atlasName: String
    var method: String
    var sliceCount: Int
    var apRangeMicrons: ClosedRange<Double>
    var meanConfidence: Double
    var meanContourScore: Double
    var meanContourDeviation: Double

    static let empty = AtlasRegistrationSummary(
        atlasName: "Allen CCF 2020",
        method: "none",
        sliceCount: 0,
        apRangeMicrons: 0...0,
        meanConfidence: 0,
        meanContourScore: 0,
        meanContourDeviation: 0
    )
}

enum ReliabilityLevel: String, Hashable {
    case atlasValidated
    case needsAtlasRegistration
    case review
    case unreliable

    var title: String {
        switch self {
        case .atlasValidated:
            "Atlas validated"
        case .needsAtlasRegistration:
            "Needs atlas registration"
        case .review:
            "Review"
        case .unreliable:
            "Unreliable"
        }
    }
}

enum ReliabilitySeverity: String, Hashable {
    case info
    case warning
    case failure
}

struct ReliabilityIssue: Identifiable, Hashable {
    let id = UUID()
    var severity: ReliabilitySeverity
    var title: String
    var detail: String
}

struct AtlasReferenceVerification: Hashable {
    var folderURL: URL?
    var expectedFiles: Int
    var presentFiles: Int
    var sizeMatchedFiles: Int
    var issues: [ReliabilityIssue]

    var isComplete: Bool {
        expectedFiles > 0
            && presentFiles == expectedFiles
            && sizeMatchedFiles == expectedFiles
            && !issues.contains { $0.severity == .failure }
    }

    var summary: String {
        if isComplete {
            return "Allen CCF files present and size-checked (\(sizeMatchedFiles)/\(expectedFiles))"
        }
        if presentFiles == 0 {
            return "Allen CCF files not found"
        }
        return "Allen CCF partial verification (\(sizeMatchedFiles)/\(expectedFiles) size-matched)"
    }
}

struct ReliabilityReport: Hashable {
    var score: Double
    var level: ReliabilityLevel
    var atlasReference: AtlasReferenceVerification
    var issues: [ReliabilityIssue]

    static let empty = ReliabilityReport(
        score: 0,
        level: .unreliable,
        atlasReference: AtlasReferenceVerification(
            folderURL: nil,
            expectedFiles: 0,
            presentFiles: 0,
            sizeMatchedFiles: 0,
            issues: []
        ),
        issues: [
            ReliabilityIssue(
                severity: .failure,
                title: "No reconstruction",
                detail: "No slices were available for validation."
            )
        ]
    )
}
