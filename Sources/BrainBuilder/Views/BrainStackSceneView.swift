import AppKit
@preconcurrency import SceneKit
import SwiftUI

enum BrainCameraPreset: String, CaseIterable, Identifiable {
    case oblique
    case front
    case side
    case top

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oblique: "3D"
        case .front: "Front"
        case .side: "Side"
        case .top: "Top"
        }
    }

    var systemImage: String {
        switch self {
        case .oblique: "view.3d"
        case .front: "square"
        case .side: "rectangle.portrait"
        case .top: "rectangle"
        }
    }
}

struct BrainCameraRequest: Equatable {
    var id = UUID()
    var preset: BrainCameraPreset = .oblique
}

struct BrainStackSceneView: NSViewRepresentable {
    var volume: BrainVolume?
    var selectedSliceID: String?
    var cameraRequest: BrainCameraRequest
    @ObservedObject var atlas: AllenAtlasService
    var retrospectiveSnapshot: Brain3DRetrospectiveOverlaySnapshot?
    var retrospectiveVisibility: Brain3DRetrospectiveOverlayVisibility

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = false
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = BrainBuilderTheme.sceneBackground
        context.coordinator.apply(
            volume: volume,
            selectedSliceID: selectedSliceID,
            cameraRequest: cameraRequest,
            atlas: atlas,
            retrospectiveSnapshot: retrospectiveSnapshot,
            retrospectiveVisibility: retrospectiveVisibility,
            to: view
        )
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        context.coordinator.apply(
            volume: volume,
            selectedSliceID: selectedSliceID,
            cameraRequest: cameraRequest,
            atlas: atlas,
            retrospectiveSnapshot: retrospectiveSnapshot,
            retrospectiveVisibility: retrospectiveVisibility,
            to: nsView
        )
    }

    @MainActor
    final class Coordinator {
        private var renderedVolumeRevision: UUID?
        private var renderedSelectedSliceID: String?
        private var renderedCameraRequestID: UUID?
        private var renderedReferenceReservesSpace: Bool?
        private var renderedRetrospectiveSnapshot: Brain3DRetrospectiveOverlaySnapshot?
        private var renderedRetrospectiveVisibility: Brain3DRetrospectiveOverlayVisibility?
        private var referenceGeneration = UUID()
        private var framing = SceneBounds.unit
        private let roiLoadQueue = DispatchQueue(
            label: "dev.camera3d.BrainBuilder.retrospective-roi-loader",
            qos: .userInitiated
        )

        func apply(
            volume: BrainVolume?,
            selectedSliceID: String?,
            cameraRequest: BrainCameraRequest,
            atlas: AllenAtlasService,
            retrospectiveSnapshot: Brain3DRetrospectiveOverlaySnapshot?,
            retrospectiveVisibility: Brain3DRetrospectiveOverlayVisibility,
            to view: SCNView
        ) {
            let volumeChanged = renderedVolumeRevision != volume?.revision || view.scene == nil
            let referencePresentationChanged = renderedReferenceReservesSpace
                != atlas.referenceMeshState.reservesReferenceSpace
            let retrospectivePresentationChanged = renderedRetrospectiveSnapshot
                != retrospectiveSnapshot
                || renderedRetrospectiveVisibility != retrospectiveVisibility
            let sceneChanged = volumeChanged
                || referencePresentationChanged
                || retrospectivePresentationChanged
            let selectionChanged = renderedSelectedSliceID != selectedSliceID
            if sceneChanged {
                referenceGeneration = UUID()
                let generation = referenceGeneration
                let build = BrainStackSceneView.makeScene(
                    volume: volume,
                    selectedSliceID: selectedSliceID,
                    includeReference: atlas.referenceMeshState.reservesReferenceSpace,
                    retrospectiveSnapshot: retrospectiveSnapshot,
                    retrospectiveVisibility: retrospectiveVisibility
                )
                view.scene = build.scene
                framing = build.framing
                renderedVolumeRevision = volume?.revision
                renderedSelectedSliceID = selectedSliceID
                renderedReferenceReservesSpace = atlas.referenceMeshState.reservesReferenceSpace
                renderedRetrospectiveSnapshot = retrospectiveSnapshot
                renderedRetrospectiveVisibility = retrospectiveVisibility

                if let placement = build.referencePlacement,
                   atlas.referenceMeshState.reservesReferenceSpace {
                    let revision = volume?.revision
                    let scene = build.scene
                    atlas.loadRootReferenceGeometry { [weak self, weak view] result in
                        guard let self, let view,
                              self.referenceGeneration == generation,
                              self.renderedVolumeRevision == revision,
                              view.scene === scene,
                              case let .success(reference) = result,
                              let placeholder = scene.rootNode.childNode(
                                withName: NodeName.referencePlaceholder,
                                recursively: true
                              ) else {
                            return
                        }
                        placeholder.childNodes.forEach { $0.removeFromParentNode() }
                        placeholder.addChildNode(
                            BrainStackSceneView.atlasReferenceNode(
                                geometry: reference.geometry,
                                placement: placement
                            )
                        )
                        view.setNeedsDisplay(view.bounds)
                    }
                }

                if let placement = build.referencePlacement,
                   let retrospectiveSnapshot,
                   retrospectiveVisibility.showsAllenROIMask,
                   !retrospectiveSnapshot.allenROIs.isEmpty {
                    loadAllenROIMeshes(
                        retrospectiveSnapshot.allenROIs,
                        atlasFolderURL: atlas.atlasFolderURL,
                        placement: placement,
                        generation: generation,
                        scene: build.scene,
                        view: view
                    )
                }
            } else if selectionChanged, let volume {
                BrainStackSceneView.updateSectionSelection(
                    selectedSliceID,
                    slices: volume.slices,
                    in: view.scene
                )
                renderedSelectedSliceID = selectedSliceID
                view.setNeedsDisplay(view.bounds)
            }

            if sceneChanged || renderedCameraRequestID != cameraRequest.id {
                BrainStackSceneView.applyCameraPreset(
                    cameraRequest.preset,
                    framing: framing,
                    to: view
                )
                renderedCameraRequestID = cameraRequest.id
            }
        }

        private func loadAllenROIMeshes(
            _ members: [Brain3DLockedAllenROI],
            atlasFolderURL: URL,
            placement: AtlasSlicePlacement,
            generation: UUID,
            scene: SCNScene,
            view: SCNView
        ) {
            let meshFolder = atlasFolderURL.appendingPathComponent("meshes", isDirectory: true)
            for member in members {
                let url = meshFolder.appendingPathComponent("\(member.structureID).obj")
                roiLoadQueue.async { [weak self, weak view] in
                    let result = autoreleasepool {
                        AllenAtlasService.loadValidatedReferenceGeometry(at: url)
                    }
                    DispatchQueue.main.async { [weak self, weak view] in
                        guard let self, let view,
                              self.referenceGeneration == generation,
                              view.scene === scene,
                              case let .success(reference) = result,
                              let placeholder = scene.rootNode.childNode(
                                withName: NodeName.allenROIPlaceholder,
                                recursively: true
                              ) else { return }
                        placeholder.addChildNode(
                            BrainStackSceneView.allenROINode(
                                geometry: reference.geometry,
                                member: member,
                                placement: placement
                            )
                        )
                        view.setNeedsDisplay(view.bounds)
                    }
                }
            }
        }
    }

    private enum NodeName {
        static let camera = "brainbuilder-camera"
        static let axisGuide = "brainbuilder-anatomical-orientation"
        static let referencePlaceholder = "allen-reference-placeholder"
        static let allenROIPlaceholder = "brain3d-allen-roi-placeholder"

        static func section(_ id: String) -> String {
            "brainbuilder-section-\(id)"
        }
    }

    private struct SceneBuild {
        var scene: SCNScene
        var framing: SceneBounds
        var referencePlacement: AtlasSlicePlacement?
    }

    private static func makeScene(
        volume: BrainVolume?,
        selectedSliceID: String?,
        includeReference: Bool,
        retrospectiveSnapshot: Brain3DRetrospectiveOverlaySnapshot?,
        retrospectiveVisibility: Brain3DRetrospectiveOverlayVisibility
    ) -> SceneBuild {
        let scene = SCNScene()
        scene.background.contents = BrainBuilderTheme.sceneBackground
        addLighting(to: scene)

        let camera = cameraNode()
        scene.rootNode.addChildNode(camera)

        guard let volume, !volume.slices.isEmpty else {
            scene.rootNode.addChildNode(emptyNode())
            return SceneBuild(scene: scene, framing: .unit, referencePlacement: nil)
        }

        let content = SCNNode()
        content.name = "registered-section-stack"
        scene.rootNode.addChildNode(content)
        var framing: SceneBounds?

        let orderedSlices = volume.slices.sorted { lhs, rhs in
            if lhs.registration.atlasAPMicrons != rhs.registration.atlasAPMicrons {
                return lhs.registration.atlasAPMicrons < rhs.registration.atlasAPMicrons
            }
            return lhs.id < rhs.id
        }
        for slice in orderedSlices {
            let isSelected = slice.id == selectedSliceID
            guard let plane = sectionPlaneNode(
                slice: slice,
                isSelected: isSelected,
                renderingOrder: isSelected ? 1_000 : 100
            ) else {
                continue
            }
            content.addChildNode(plane.node)
            framing = framing.map { $0.including(plane.corners) }
                ?? SceneBounds(points: plane.corners)
        }

        let referencePlacement = orderedSlices.compactMap(\.atlasPlacement).first
        if let referencePlacement, includeReference {
            let placeholder = SCNNode()
            placeholder.name = NodeName.referencePlaceholder
            content.addChildNode(placeholder)
            let atlasCorners = referenceBoundsPoints(placement: referencePlacement)
            framing = framing.map { $0.including(atlasCorners) }
                ?? SceneBounds(points: atlasCorners)
        }

        if let referencePlacement,
           let retrospectiveSnapshot,
           retrospectiveSnapshot.usableForNavigation == false {
            let overlay = retrospectiveOverlayNode(
                snapshot: retrospectiveSnapshot,
                visibility: retrospectiveVisibility,
                placement: referencePlacement
            )
            content.addChildNode(overlay.node)
            if !overlay.points.isEmpty {
                framing = framing.map { $0.including(overlay.points) }
                    ?? SceneBounds(points: overlay.points)
            }
            if retrospectiveVisibility.showsAllenROIMask,
               !retrospectiveSnapshot.allenROIs.isEmpty {
                let placeholder = SCNNode()
                placeholder.name = NodeName.allenROIPlaceholder
                content.addChildNode(placeholder)
            }
        }

        let resolvedFraming = framing ?? .unit
        content.addChildNode(axisGuideNode(bounds: resolvedFraming))
        return SceneBuild(
            scene: scene,
            framing: resolvedFraming,
            referencePlacement: referencePlacement
        )
    }

    private static func addLighting(to scene: SCNScene) {
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 260
        ambient.color = NSColor(calibratedWhite: 0.82, alpha: 1)
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        let key = SCNLight()
        key.type = .directional
        key.intensity = 720
        key.temperature = 5_800
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.eulerAngles = SCNVector3(-0.72, -0.58, -0.18)
        scene.rootNode.addChildNode(keyNode)

        let fill = SCNLight()
        fill.type = .directional
        fill.intensity = 260
        fill.temperature = 7_200
        let fillNode = SCNNode()
        fillNode.light = fill
        fillNode.eulerAngles = SCNVector3(0.45, 2.2, 0)
        scene.rootNode.addChildNode(fillNode)
    }

    private static func atlasReferenceNode(
        geometry: SCNGeometry,
        placement: AtlasSlicePlacement
    ) -> SCNNode {
        let node = SCNNode(geometry: geometry)
        node.name = "Allen CCFv3 anatomical reference (not specimen tissue)"
        node.simdTransform = AtlasSceneGeometry.sceneTransform(
            atlasCenterMicrons: placement.atlasCenterMicrons,
            sceneMicronsPerUnit: placement.sceneMicronsPerUnit
        ) ?? matrix_identity_float4x4
        node.renderingOrder = -100
        return node
    }

    private struct RetrospectiveSceneOverlay {
        var node: SCNNode
        var points: [SIMD3<Float>]
    }

    private static func retrospectiveOverlayNode(
        snapshot: Brain3DRetrospectiveOverlaySnapshot,
        visibility: Brain3DRetrospectiveOverlayVisibility,
        placement: AtlasSlicePlacement
    ) -> RetrospectiveSceneOverlay {
        let root = SCNNode()
        root.name = "Brain3D retrospective evidence (not for navigation)"
        root.renderingOrder = 1_500
        var points: [SIMD3<Float>] = []
        let scale = placement.sceneMicronsPerUnit

        if visibility.showsPlannedShanks {
            for segment in snapshot.plannedSegments {
                guard let first = AtlasSceneGeometry.scenePoint(
                    atlasASRMicrons: segment.endpointAASRMicrometres,
                    atlasCenterMicrons: placement.atlasCenterMicrons,
                    sceneMicronsPerUnit: scale
                ), let second = AtlasSceneGeometry.scenePoint(
                    atlasASRMicrons: segment.endpointBASRMicrometres,
                    atlasCenterMicrons: placement.atlasCenterMicrons,
                    sceneMicronsPerUnit: scale
                ) else { continue }
                let node = solidSegmentNode(
                    from: first,
                    to: second,
                    radius: max(0.0008, Float(14 / scale)),
                    color: .systemYellow,
                    name: "Planned physical shank \(segment.id) · solid"
                )
                root.addChildNode(node)
                points.append(contentsOf: [first, second])
            }
        }

        if visibility.showsObservedEvidence {
            for segment in snapshot.observedSegments {
                guard let endpointA = AtlasSceneGeometry.scenePoint(
                    atlasASRMicrons: segment.endpointAASRMicrometres,
                    atlasCenterMicrons: placement.atlasCenterMicrons,
                    sceneMicronsPerUnit: scale
                ), let endpointB = AtlasSceneGeometry.scenePoint(
                    atlasASRMicrons: segment.endpointBASRMicrometres,
                    atlasCenterMicrons: placement.atlasCenterMicrons,
                    sceneMicronsPerUnit: scale
                ) else { continue }
                root.addChildNode(
                    dashedSegmentNode(
                        from: endpointA,
                        to: endpointB,
                        dashLength: max(0.004, Float(80 / scale)),
                        gapLength: max(0.002, Float(45 / scale)),
                        radius: max(0.00075, Float(12 / scale)),
                        color: NSColor(calibratedWhite: 0.82, alpha: 1),
                        name: "Observed finite evidence \(segment.id) · dashed"
                    )
                )
                root.addChildNode(
                    evidenceEndpointNode(
                        at: endpointA,
                        radius: max(0.002, Float(24 / scale)),
                        name: "Observed \(segment.id) endpoint A"
                    )
                )
                root.addChildNode(
                    evidenceEndpointNode(
                        at: endpointB,
                        radius: max(0.002, Float(24 / scale)),
                        name: "Observed \(segment.id) endpoint B"
                    )
                )
                points.append(contentsOf: [endpointA, endpointB])
            }
        }

        if visibility.showsASRBoxes {
            for box in snapshot.asrBoxes {
                let vertices = Brain3DRetrospectiveOverlayGeometry.boxVertices(
                    minimum: box.minimumASRMicrometres,
                    maximum: box.maximumASRMicrometres
                ).compactMap {
                    AtlasSceneGeometry.scenePoint(
                        atlasASRMicrons: $0,
                        atlasCenterMicrons: placement.atlasCenterMicrons,
                        sceneMicronsPerUnit: scale
                    )
                }
                guard vertices.count == 8 else { continue }
                let boxRoot = SCNNode()
                boxRoot.name = "ASR box ROI \(box.roiSetName) / \(box.boxID)"
                for (firstIndex, secondIndex) in Brain3DRetrospectiveOverlayGeometry.boxEdgeIndices {
                    boxRoot.addChildNode(
                        solidSegmentNode(
                            from: vertices[firstIndex],
                            to: vertices[secondIndex],
                            radius: max(0.0005, Float(8 / scale)),
                            color: .systemOrange,
                            name: "ASR box edge"
                        )
                    )
                }
                root.addChildNode(boxRoot)
                points.append(contentsOf: vertices)
            }
        }
        return RetrospectiveSceneOverlay(node: root, points: points)
    }

    private static func solidSegmentNode(
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        radius: Float,
        color: NSColor,
        name: String
    ) -> SCNNode {
        let vector = end - start
        let length = simd_length(vector)
        guard length.isFinite, length > 1e-9 else { return SCNNode() }
        let cylinder = SCNCylinder(radius: CGFloat(radius), height: CGFloat(length))
        cylinder.radialSegmentCount = 10
        let material = retrospectiveMaterial(color: color, transparency: 0.96)
        cylinder.materials = [material]
        let node = SCNNode(geometry: cylinder)
        node.name = name
        node.renderingOrder = 1_500
        node.position = SCNVector3(
            (start.x + end.x) / 2,
            (start.y + end.y) / 2,
            (start.z + end.z) / 2
        )
        node.look(
            at: SCNVector3(end.x, end.y, end.z),
            up: SCNVector3(0, 1, 0),
            localFront: SCNVector3(0, 1, 0)
        )
        return node
    }

    private static func dashedSegmentNode(
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        dashLength: Float,
        gapLength: Float,
        radius: Float,
        color: NSColor,
        name: String
    ) -> SCNNode {
        let root = SCNNode()
        root.name = name
        let vector = end - start
        let length = simd_length(vector)
        guard length.isFinite, length > 1e-9,
              dashLength > 0, gapLength >= 0 else { return root }
        let direction = vector / length
        var distance: Float = 0
        while distance < length {
            let dashEnd = min(length, distance + dashLength)
            root.addChildNode(
                solidSegmentNode(
                    from: start + direction * distance,
                    to: start + direction * dashEnd,
                    radius: radius,
                    color: color,
                    name: "Observed evidence dash"
                )
            )
            distance += dashLength + gapLength
        }
        return root
    }

    private static func evidenceEndpointNode(
        at point: SIMD3<Float>,
        radius: Float,
        name: String
    ) -> SCNNode {
        let sphere = SCNSphere(radius: CGFloat(radius))
        sphere.segmentCount = 12
        sphere.materials = [
            retrospectiveMaterial(
                color: NSColor(calibratedWhite: 0.86, alpha: 1),
                transparency: 0.96
            )
        ]
        let node = SCNNode(geometry: sphere)
        node.name = name
        node.simdPosition = point
        node.renderingOrder = 1_501
        return node
    }

    private static func allenROINode(
        geometry: SCNGeometry,
        member: Brain3DLockedAllenROI,
        placement: AtlasSlicePlacement
    ) -> SCNNode {
        let resolvedGeometry = geometry.copy() as? SCNGeometry ?? geometry
        resolvedGeometry.materials = [
            retrospectiveMaterial(color: .systemTeal, transparency: 0.16)
        ]
        let node = SCNNode(geometry: resolvedGeometry)
        node.name = "Allen ROI reference mesh \(member.roiSetName) · structure \(member.structureID)"
        node.simdTransform = AtlasSceneGeometry.sceneTransform(
            atlasCenterMicrons: placement.atlasCenterMicrons,
            sceneMicronsPerUnit: placement.sceneMicronsPerUnit
        ) ?? matrix_identity_float4x4
        node.renderingOrder = 1_200
        return node
    }

    private static func retrospectiveMaterial(
        color: NSColor,
        transparency: CGFloat
    ) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.transparency = transparency
        material.transparencyMode = .singleLayer
        material.blendMode = .alpha
        material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = false
        return material
    }

    private struct SectionPlane {
        var node: SCNNode
        var corners: [SIMD3<Float>]
    }

    private static func sectionPlaneNode(
        slice: VolumeSlice,
        isSelected: Bool,
        renderingOrder: Int
    ) -> SectionPlane? {
        guard let corners = sectionCorners(slice: slice), corners.count == 4 else {
            return nil
        }
        let vertexSource = SCNGeometrySource(
            vertices: corners.map { SCNVector3($0.x, $0.y, $0.z) }
        )
        let textureSource = SCNGeometrySource(textureCoordinates: [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 1, y: 0),
            CGPoint(x: 1, y: 1),
            CGPoint(x: 0, y: 1),
        ])
        let surface = SCNGeometryElement(
            indices: [UInt32(0), 1, 2, 0, 2, 3],
            primitiveType: .triangles
        )
        let outline = SCNGeometryElement(
            indices: [UInt32(0), 1, 1, 2, 2, 3, 3, 0],
            primitiveType: .line
        )
        let geometry = SCNGeometry(
            sources: [vertexSource, textureSource],
            elements: [surface, outline]
        )
        let isReviewed = slice.atlasPlacement?.isReviewed == true
        let texture = SCNMaterial()
        texture.name = isSelected
            ? "Selected section"
            : (isReviewed ? "Accepted section" : "Section preview")
        texture.diffuse.contents = slice.texture
        texture.diffuse.magnificationFilter = .linear
        texture.diffuse.minificationFilter = .linear
        texture.diffuse.mipFilter = .linear
        texture.diffuse.maxAnisotropy = 8
        texture.lightingModel = .constant
        texture.isDoubleSided = true
        texture.transparencyMode = .singleLayer
        texture.blendMode = .alpha
        texture.readsFromDepthBuffer = true
        texture.writesToDepthBuffer = false

        let border = SCNMaterial()
        border.lightingModel = .constant
        border.readsFromDepthBuffer = false
        border.writesToDepthBuffer = false
        geometry.materials = [texture, border]

        let node = SCNNode(geometry: geometry)
        node.name = NodeName.section(slice.id)
        applySectionVisualState(
            to: node,
            isReviewed: isReviewed,
            isSelected: isSelected,
            renderingOrder: renderingOrder
        )
        return SectionPlane(node: node, corners: corners)
    }

    private static func updateSectionSelection(
        _ selectedSliceID: String?,
        slices: [VolumeSlice],
        in scene: SCNScene?
    ) {
        for slice in slices {
            guard let node = scene?.rootNode.childNode(
                withName: NodeName.section(slice.id),
                recursively: true
            ) else { continue }
            let isSelected = slice.id == selectedSliceID
            applySectionVisualState(
                to: node,
                isReviewed: slice.atlasPlacement?.isReviewed == true,
                isSelected: isSelected,
                renderingOrder: isSelected ? 1_000 : 100
            )
        }
    }

    private static func applySectionVisualState(
        to node: SCNNode,
        isReviewed: Bool,
        isSelected: Bool,
        renderingOrder: Int
    ) {
        guard let materials = node.geometry?.materials, materials.count >= 2 else { return }
        let texture = materials[0]
        texture.name = isSelected
            ? "Selected section"
            : (isReviewed ? "Accepted section" : "Section preview")
        texture.transparency = isSelected ? 0.88 : (isReviewed ? 0.26 : 0.08)

        let border = materials[1]
        border.name = isReviewed ? "Accepted section border" : "Preview section border"
        border.diffuse.contents = isReviewed ? NSColor.systemGreen : NSColor.systemOrange
        border.transparency = 0
        node.renderingOrder = renderingOrder
    }

    private static func sectionCorners(slice: VolumeSlice) -> [SIMD3<Float>]? {
        if let placement = slice.atlasPlacement {
            let width = Double(placement.planeSize.width)
            let height = Double(placement.planeSize.height)
            let values = [
                placement.scenePoint(pixelX: 0, pixelY: 0),
                placement.scenePoint(pixelX: width, pixelY: 0),
                placement.scenePoint(pixelX: width, pixelY: height),
                placement.scenePoint(pixelX: 0, pixelY: height),
            ]
            guard values.allSatisfy({ $0 != nil }) else { return nil }
            return values.compactMap { $0 }
        }

        let left = Float(-slice.width / 2 + slice.offsetX)
        let right = Float(slice.width / 2 + slice.offsetX)
        let top = Float(slice.height / 2 + slice.offsetY)
        let bottom = Float(-slice.height / 2 + slice.offsetY)
        let z = Float(slice.z)
        return [
            SIMD3<Float>(left, top, z),
            SIMD3<Float>(right, top, z),
            SIMD3<Float>(right, bottom, z),
            SIMD3<Float>(left, bottom, z),
        ]
    }

    private static func referenceBoundsPoints(
        placement: AtlasSlicePlacement
    ) -> [SIMD3<Float>] {
        let atlas = AllenCCFReference.default
        let maxPoint = SIMD3<Double>(
            Double(atlas.dimensionsVoxels.x - 1) * atlas.voxelSizeMicrons,
            Double(atlas.dimensionsVoxels.y - 1) * atlas.voxelSizeMicrons,
            Double(atlas.dimensionsVoxels.z - 1) * atlas.voxelSizeMicrons
        )
        return [0.0, maxPoint.x].flatMap { ap in
            [0.0, maxPoint.y].flatMap { si in
                [0.0, maxPoint.z].compactMap { rl in
                    AtlasSceneGeometry.scenePoint(
                        atlasASRMicrons: SIMD3<Double>(ap, si, rl),
                        atlasCenterMicrons: placement.atlasCenterMicrons,
                        sceneMicronsPerUnit: placement.sceneMicronsPerUnit
                    )
                }
            }
        }
    }

    struct SceneBounds {
        var min: SIMD3<Float>
        var max: SIMD3<Float>

        static let unit = SceneBounds(
            min: SIMD3<Float>(repeating: -0.5),
            max: SIMD3<Float>(repeating: 0.5)
        )

        private init(min: SIMD3<Float>, max: SIMD3<Float>) {
            self.min = min
            self.max = max
        }

        init(points: [SIMD3<Float>]) {
            min = points.first ?? Self.unit.min
            max = min
            for point in points.dropFirst() {
                min = simd_min(min, point)
                max = simd_max(max, point)
            }
        }

        var center: SIMD3<Float> { (min + max) / 2 }

        var extent: Float {
            let delta = max - min
            return Swift.max(delta.x, Swift.max(delta.y, delta.z))
        }

        func including(_ points: [SIMD3<Float>]) -> SceneBounds {
            var result = self
            for point in points {
                result.min = simd_min(result.min, point)
                result.max = simd_max(result.max, point)
            }
            return result
        }
    }

    private static func cameraNode() -> SCNNode {
        let node = SCNNode()
        node.name = NodeName.camera
        let camera = SCNCamera()
        camera.fieldOfView = 36
        camera.wantsHDR = false
        node.camera = camera
        return node
    }

    private static func applyCameraPreset(
        _ preset: BrainCameraPreset,
        framing: SceneBounds,
        to view: SCNView
    ) {
        guard let cameraNode = view.scene?.rootNode.childNode(
            withName: NodeName.camera,
            recursively: true
        ) else { return }
        let direction: SIMD3<Float>
        let up: SIMD3<Float>
        switch preset {
        case .oblique:
            direction = simd_normalize(SIMD3<Float>(0.72, 0.42, -1.0))
            up = SIMD3<Float>(0, 1, 0)
        case .front:
            direction = SIMD3<Float>(0, 0, -1)
            up = SIMD3<Float>(0, 1, 0)
        case .side:
            direction = SIMD3<Float>(1, 0, 0)
            up = SIMD3<Float>(0, 1, 0)
        case .top:
            direction = SIMD3<Float>(0, 1, 0)
            up = SIMD3<Float>(0, 0, 1)
        }
        let distance = max(1.8, framing.extent * 1.78)
        let target = framing.center
        let position = target + direction * distance
        let forward = simd_normalize(target - position)
        let right = simd_normalize(simd_cross(forward, up))
        let correctedUp = simd_normalize(simd_cross(right, forward))
        cameraNode.simdTransform = simd_float4x4(columns: (
            SIMD4<Float>(right, 0),
            SIMD4<Float>(correctedUp, 0),
            SIMD4<Float>(-forward, 0),
            SIMD4<Float>(position, 1)
        ))
        view.pointOfView = cameraNode
        view.defaultCameraController.target = SCNVector3(
            target.x,
            target.y,
            target.z
        )
        if let axisGuide = view.scene?.rootNode.childNode(
            withName: NodeName.axisGuide,
            recursively: true
        ) {
            axisGuide.simdPosition = target
                + right * (framing.extent * 0.54)
                - correctedUp * (framing.extent * 0.42)
        }
        cameraNode.camera?.zNear = Double(max(0.001, framing.extent * 0.002))
        cameraNode.camera?.zFar = Double(max(100, framing.extent * 20))
    }

    private static func axisGuideNode(bounds: SceneBounds) -> SCNNode {
        let root = SCNNode()
        root.name = NodeName.axisGuide
        root.renderingOrder = 2_000
        let length = max(0.12, bounds.extent * 0.12)
        let origin = SIMD3<Float>.zero
        root.addChildNode(axisNode(
            from: origin,
            to: origin + SIMD3<Float>(length, 0, 0),
            color: .systemRed
        ))
        root.addChildNode(axisNode(
            from: origin,
            to: origin + SIMD3<Float>(0, length, 0),
            color: .systemGreen
        ))
        root.addChildNode(axisNode(
            from: origin,
            to: origin + SIMD3<Float>(0, 0, length),
            color: .systemBlue
        ))
        return root
    }

    private static func axisNode(
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        color: NSColor
    ) -> SCNNode {
        let root = SCNNode()
        let vector = end - start
        let length = simd_length(vector)
        let cylinder = SCNCylinder(radius: CGFloat(length * 0.018), height: CGFloat(length))
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.lightingModel = .constant
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        cylinder.materials = [material]
        let line = SCNNode(geometry: cylinder)
        line.renderingOrder = 2_000
        line.position = SCNVector3(
            (start.x + end.x) / 2,
            (start.y + end.y) / 2,
            (start.z + end.z) / 2
        )
        line.look(
            at: SCNVector3(end.x, end.y, end.z),
            up: SCNVector3(0, 1, 0),
            localFront: SCNVector3(0, 1, 0)
        )
        root.addChildNode(line)
        return root
    }

    private static func emptyNode() -> SCNNode {
        let text = SCNText(string: "No 3D stack", extrusionDepth: 0.01)
        text.font = NSFont.systemFont(ofSize: 0.12, weight: .medium)
        text.firstMaterial?.diffuse.contents = NSColor.secondaryLabelColor

        let node = SCNNode(geometry: text)
        node.position = SCNVector3(-0.45, 0, 0)
        return node
    }
}
