import AppKit
import Foundation
import ModelIO
import SceneKit
import SceneKit.ModelIO

struct AllenReferenceMeshMetrics: Equatable, Sendable {
    var vertexCount: Int
    var primitiveCount: Int
}

enum AllenReferenceMeshLoadState: Equatable, Sendable {
    case loading
    case loaded(AllenReferenceMeshMetrics)
    case unavailable
    case failed(String)

    var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }

    var isLoading: Bool {
        self == .loading
    }

    /// Loading and loaded states reserve the same atlas bounds so validation
    /// completing never causes the camera framing to jump.
    var reservesReferenceSpace: Bool {
        switch self {
        case .loading, .loaded:
            true
        case .unavailable, .failed:
            false
        }
    }

    var conciseDescription: String {
        switch self {
        case .loading:
            "Validating Allen CCFv3 root mesh"
        case let .loaded(metrics):
            "Allen CCFv3 root mesh loaded (\(metrics.vertexCount) vertices, \(metrics.primitiveCount) faces)"
        case .unavailable:
            "Allen CCFv3 root mesh unavailable"
        case let .failed(message):
            "Allen CCFv3 root mesh failed validation: \(message)"
        }
    }
}

enum AllenReferenceMeshLoadError: LocalizedError, Equatable {
    case unavailable
    case unsupportedFormat(String)
    case invalidGeometry(String)
    case superseded

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "The root mesh file is not installed."
        case let .unsupportedFormat(extensionName):
            "ModelIO cannot import .\(extensionName) files."
        case let .invalidGeometry(reason):
            reason
        case .superseded:
            "A newer reference-mesh load replaced this request."
        }
    }
}

struct AllenReferenceGeometry {
    var geometry: SCNGeometry
    var metrics: AllenReferenceMeshMetrics
}

@MainActor
final class AllenAtlasService: ObservableObject {
    static let shared = AllenAtlasService()

    @Published private(set) var status: String = "Allen CCF not downloaded"
    @Published private(set) var isDownloading = false
    @Published private(set) var referenceMeshState: AllenReferenceMeshLoadState

    let resources = AllenAtlasCatalog.resources

    private struct ReferenceMeshFingerprint: Equatable {
        var path: String
        var fileSize: Int
        var modificationTime: TimeInterval
    }

    typealias ReferenceGeometryLoader = (URL) -> Result<AllenReferenceGeometry, AllenReferenceMeshLoadError>
    typealias ReferenceGeometryCompletion = (Result<AllenReferenceGeometry, AllenReferenceMeshLoadError>) -> Void

    private let fileManager: FileManager
    private let referenceMeshURL: URL
    private let referenceLoadQueue: DispatchQueue
    private let referenceGeometryLoader: ReferenceGeometryLoader
    private var referenceLoadGeneration = UUID()
    private var activeReferenceFingerprint: ReferenceMeshFingerprint?
    private var loadedReferenceFingerprint: ReferenceMeshFingerprint?
    private var loadedReferenceGeometry: AllenReferenceGeometry?
    private var pendingReferenceCompletions: [ReferenceGeometryCompletion] = []

    init(
        referenceMeshURL: URL = AllenAtlasCatalog.rootStructureMeshURL,
        fileManager: FileManager = .default,
        referenceLoadQueue: DispatchQueue = DispatchQueue(
            label: "dev.camera3d.BrainBuilder.atlas-reference-loader",
            qos: .userInitiated
        ),
        referenceGeometryLoader: @escaping ReferenceGeometryLoader = AllenAtlasService.loadValidatedReferenceGeometry
    ) {
        self.referenceMeshURL = referenceMeshURL
        self.fileManager = fileManager
        self.referenceLoadQueue = referenceLoadQueue
        self.referenceGeometryLoader = referenceGeometryLoader
        referenceMeshState = fileManager.fileExists(atPath: referenceMeshURL.path)
            ? .loading
            : .unavailable
    }

    var atlasFolderURL: URL {
        AllenAtlasCatalog.atlasInstallationURL
    }

    func refreshStatus() {
        let available = resources.filter { resource in
            let url = localURL(for: resource)
            guard FileManager.default.fileExists(atPath: url.path),
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                return false
            }
            return size == resource.expectedBytes
        }
        if available.count == resources.count {
            status = "BrainGlobe Allen CCF ready (25 um v1.2)"
        } else if available.isEmpty {
            status = "Allen CCF downloads automatically on first registration"
        } else {
            status = "Allen CCF partial download (\(available.count)/\(resources.count))"
        }
        loadRootReferenceGeometry { _ in }
    }

    /// Loads and validates the ModelIO geometry. File existence alone never
    /// transitions this service to `.loaded`.
    func loadRootReferenceGeometry(
        forceReload: Bool = false,
        completion: @escaping ReferenceGeometryCompletion
    ) {
        guard let fingerprint = referenceFingerprint() else {
            invalidateReferenceLoad()
            setReferenceMeshState(.unavailable)
            completion(.failure(.unavailable))
            return
        }

        if !forceReload,
           loadedReferenceFingerprint == fingerprint,
           let loadedReferenceGeometry {
            setReferenceMeshState(.loaded(loadedReferenceGeometry.metrics))
            completion(.success(loadedReferenceGeometry))
            return
        }

        if !forceReload,
           activeReferenceFingerprint == fingerprint,
           referenceMeshState.isLoading {
            pendingReferenceCompletions.append(completion)
            return
        }

        let supersededCompletions = pendingReferenceCompletions
        pendingReferenceCompletions = [completion]
        supersededCompletions.forEach { $0(.failure(.superseded)) }

        let generation = UUID()
        referenceLoadGeneration = generation
        activeReferenceFingerprint = fingerprint
        loadedReferenceFingerprint = nil
        loadedReferenceGeometry = nil
        setReferenceMeshState(.loading)

        let url = referenceMeshURL
        let loader = referenceGeometryLoader
        referenceLoadQueue.async { [weak self] in
            let result = autoreleasepool {
                loader(url)
            }
            DispatchQueue.main.async { [weak self] in
                self?.finishReferenceLoad(
                    result,
                    generation: generation,
                    fingerprint: fingerprint
                )
            }
        }
    }

    func downloadReferenceSet() async {
        guard !isDownloading else { return }
        isDownloading = true
        status = "Downloading BrainGlobe Allen CCF (about 99 MB)..."
        defer {
            isDownloading = false
            refreshStatus()
        }

        do {
            let output = AllenAtlasCatalog.brainGlobeCacheURL.appendingPathComponent("doctor", isDirectory: true)
            let result = try await Task.detached(priority: .userInitiated) {
                try RegistrationWorkerService().doctor(outputURL: output)
            }.value
            status = result.messages.first ?? "BrainGlobe Allen CCF ready"
        } catch {
            status = "Allen download failed: \(error.localizedDescription)"
        }
    }

    func openAtlasFolder() {
        try? FileManager.default.createDirectory(at: atlasFolderURL, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([atlasFolderURL])
    }

    func localURL(for resource: AllenAtlasResource) -> URL {
        atlasFolderURL.appendingPathComponent(resource.filename)
    }

    private func finishReferenceLoad(
        _ result: Result<AllenReferenceGeometry, AllenReferenceMeshLoadError>,
        generation: UUID,
        fingerprint: ReferenceMeshFingerprint
    ) {
        guard referenceLoadGeneration == generation,
              activeReferenceFingerprint == fingerprint else {
            return
        }

        guard referenceFingerprint() == fingerprint else {
            let completions = pendingReferenceCompletions
            pendingReferenceCompletions.removeAll()
            activeReferenceFingerprint = nil
            loadRootReferenceGeometry(forceReload: true) { result in
                completions.forEach { $0(result) }
            }
            return
        }

        let completions = pendingReferenceCompletions
        pendingReferenceCompletions.removeAll()
        activeReferenceFingerprint = nil

        switch result {
        case let .success(reference):
            loadedReferenceFingerprint = fingerprint
            loadedReferenceGeometry = reference
            setReferenceMeshState(.loaded(reference.metrics))
        case let .failure(error):
            loadedReferenceFingerprint = nil
            loadedReferenceGeometry = nil
            setReferenceMeshState(.failed(error.localizedDescription))
        }
        completions.forEach { $0(result) }
    }

    private func invalidateReferenceLoad() {
        referenceLoadGeneration = UUID()
        activeReferenceFingerprint = nil
        loadedReferenceFingerprint = nil
        loadedReferenceGeometry = nil
        let completions = pendingReferenceCompletions
        pendingReferenceCompletions.removeAll()
        completions.forEach { $0(.failure(.unavailable)) }
    }

    private func setReferenceMeshState(_ state: AllenReferenceMeshLoadState) {
        guard referenceMeshState != state else { return }
        referenceMeshState = state
    }

    private func referenceFingerprint() -> ReferenceMeshFingerprint? {
        guard fileManager.fileExists(atPath: referenceMeshURL.path),
              let values = try? referenceMeshURL.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
              ),
              values.isRegularFile == true else {
            return nil
        }
        return ReferenceMeshFingerprint(
            path: referenceMeshURL.standardizedFileURL.path,
            fileSize: values.fileSize ?? -1,
            modificationTime: values.contentModificationDate?.timeIntervalSince1970 ?? -1
        )
    }

    nonisolated static func loadValidatedReferenceGeometry(
        at url: URL
    ) -> Result<AllenReferenceGeometry, AllenReferenceMeshLoadError> {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure(.unavailable)
        }
        guard MDLAsset.canImportFileExtension(url.pathExtension) else {
            return .failure(.unsupportedFormat(url.pathExtension.lowercased()))
        }

        let asset = MDLAsset(url: url)
        let meshes = asset.childObjects(of: MDLMesh.self).compactMap { $0 as? MDLMesh }
        guard meshes.count == 1, let mesh = meshes.first else {
            return .failure(.invalidGeometry("Expected one mesh, found \(meshes.count)."))
        }
        guard mesh.vertexCount >= 3,
              let submeshes = mesh.submeshes,
              submeshes.count > 0 else {
            return .failure(.invalidGeometry("The mesh has no usable vertices or faces."))
        }

        if mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeNormal) == nil {
            mesh.addNormals(
                withAttributeNamed: MDLVertexAttributeNormal,
                creaseThreshold: 0.82
            )
        }
        guard mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeNormal) != nil else {
            return .failure(.invalidGeometry("ModelIO could not produce surface normals."))
        }

        let geometry = SCNGeometry(mdlMesh: mesh)
        let vertexCount = geometry.sources(for: .vertex).first?.vectorCount ?? 0
        let normalCount = geometry.sources(for: .normal).first?.vectorCount ?? 0
        let primitiveCount = geometry.elements.reduce(0) { $0 + $1.primitiveCount }
        let bounds = geometry.boundingBox
        let values = [
            bounds.min.x, bounds.min.y, bounds.min.z,
            bounds.max.x, bounds.max.y, bounds.max.z,
        ]
        let extent = SIMD3<Float>(
            Float(bounds.max.x - bounds.min.x),
            Float(bounds.max.y - bounds.min.y),
            Float(bounds.max.z - bounds.min.z)
        )
        guard vertexCount >= 3,
              normalCount == vertexCount,
              primitiveCount > 0,
              values.allSatisfy(\.isFinite),
              max(extent.x, max(extent.y, extent.z)) > 0 else {
            return .failure(.invalidGeometry("SceneKit geometry validation failed."))
        }

        geometry.name = "Allen CCFv3 root reference"
        geometry.materials = [atlasReferenceMaterial()]
        return .success(
            AllenReferenceGeometry(
                geometry: geometry,
                metrics: AllenReferenceMeshMetrics(
                    vertexCount: vertexCount,
                    primitiveCount: primitiveCount
                )
            )
        )
    }

    nonisolated private static func atlasReferenceMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.name = "Translucent Allen reference"
        material.diffuse.contents = NSColor(
            calibratedRed: 0.31,
            green: 0.58,
            blue: 0.73,
            alpha: 1
        )
        material.roughness.contents = 0.86
        material.metalness.contents = 0.0
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.transparency = 0.10
        material.transparencyMode = .singleLayer
        material.blendMode = .alpha
        material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = false
        return material
    }
}

struct AllenAtlasResource: Identifiable, Hashable {
    var id: String { filename }
    var title: String
    var filename: String
    var expectedBytes: Int

    var expectedSizeDescription: String {
        ByteCountFormatter.string(fromByteCount: Int64(expectedBytes), countStyle: .file)
    }
}

enum AllenAtlasCatalog {
    static var applicationSupportURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("BrainBuilder", isDirectory: true)
    }

    static var brainGlobeCacheURL: URL {
        applicationSupportURL.appendingPathComponent("BrainGlobe", isDirectory: true)
    }

    static var atlasInstallationURL: URL {
        brainGlobeCacheURL
            .appendingPathComponent("atlases", isDirectory: true)
            .appendingPathComponent("allen_mouse_25um_v1.2", isDirectory: true)
    }

    static var defaultAtlasFolderURL: URL { atlasInstallationURL }

    /// BrainGlobe ships the versioned root-structure mesh with the atlas.
    /// Structure 997 is the ontology root and provides anatomical context;
    /// it is never presented as measured tissue from the current specimen.
    static var rootStructureMeshURL: URL {
        atlasInstallationURL
            .appendingPathComponent("meshes", isDirectory: true)
            .appendingPathComponent("997.obj")
    }

    static let resources: [AllenAtlasResource] = [
        AllenAtlasResource(
            title: "Allen CCFv3 reference template (25 um)",
            filename: "reference.tiff",
            expectedBytes: 154_179_306
        ),
        AllenAtlasResource(
            title: "Allen CCFv3 annotation labels (25 um)",
            filename: "annotation.tiff",
            expectedBytes: 308_270_826
        ),
        AllenAtlasResource(
            title: "BrainGlobe atlas metadata",
            filename: "metadata.json",
            expectedBytes: 423
        ),
        AllenAtlasResource(
            title: "Allen CCFv3 structure hierarchy",
            filename: "structures.json",
            expectedBytes: 138_106
        )
    ]
}
