import AppKit
import simd
import XCTest
@testable import BrainBuilder

final class GeometryPipelineTests: XCTestCase {
    func testAtlasScenePointUsesRightDorsalPosteriorAxes() throws {
        let center = SIMD3<Double>(6_600, 3_800, 5_700)
        let point = SIMD3<Double>(7_100, 3_200, 4_900)

        let mapped = try XCTUnwrap(
            AtlasSceneGeometry.scenePoint(
                atlasASRMicrons: point,
                atlasCenterMicrons: center,
                sceneMicronsPerUnit: 1_000
            )
        )

        XCTAssertEqual(mapped.x, 0.8, accuracy: 0.000_001)
        XCTAssertEqual(mapped.y, 0.6, accuracy: 0.000_001)
        XCTAssertEqual(mapped.z, 0.5, accuracy: 0.000_001)
    }

    func testAtlasSceneTransformMatchesAuthoritativePointMapping() throws {
        let center = SIMD3<Double>(6_600, 3_800, 5_700)
        let point = SIMD3<Double>(7_100, 3_200, 4_900)
        let expected = try XCTUnwrap(
            AtlasSceneGeometry.scenePoint(
                atlasASRMicrons: point,
                atlasCenterMicrons: center,
                sceneMicronsPerUnit: 1_000
            )
        )
        let transform = try XCTUnwrap(
            AtlasSceneGeometry.sceneTransform(
                atlasCenterMicrons: center,
                sceneMicronsPerUnit: 1_000
            )
        )

        let transformed = transform * SIMD4<Float>(
            Float(point.x),
            Float(point.y),
            Float(point.z),
            1
        )

        XCTAssertEqual(transformed.x, expected.x, accuracy: 0.000_001)
        XCTAssertEqual(transformed.y, expected.y, accuracy: 0.000_001)
        XCTAssertEqual(transformed.z, expected.z, accuracy: 0.000_001)
        XCTAssertEqual(transformed.w, 1, accuracy: 0.000_001)
    }

    func testAtlasSceneGeometryRejectsInvalidScale() {
        XCTAssertNil(
            AtlasSceneGeometry.scenePoint(
                atlasASRMicrons: .zero,
                atlasCenterMicrons: .zero,
                sceneMicronsPerUnit: 0
            )
        )
        XCTAssertNil(
            AtlasSceneGeometry.sceneTransform(
                atlasCenterMicrons: .zero,
                sceneMicronsPerUnit: -.infinity
            )
        )
    }

    func testRegistrationMaterializationRestoresRawRasterOrientation() throws {
        let rawCGImage = try makeWarmImage(width: 18, height: 12) { context in
            context.setFillColor(CGColor(red: 0.1, green: 0.8, blue: 0.3, alpha: 1))
            context.fill(CGRect(x: 1, y: 2, width: 5, height: 4))
        }
        let rawImage = NSImage(
            cgImage: rawCGImage,
            size: NSSize(width: rawCGImage.width, height: rawCGImage.height)
        )
        let canonicalImage = try XCTUnwrap(ImageProcessingService.rotated180(rawImage))

        let restored = try RegistrationWorkerService.sourceRaster(
            canonicalImage,
            undoingCanonicalRotationDegrees: 180
        )
        let unchanged = try RegistrationWorkerService.sourceRaster(
            rawImage,
            undoingCanonicalRotationDegrees: 0
        )

        XCTAssertEqual(try rgbaPixels(from: restored), try rgbaPixels(from: rawImage))
        XCTAssertEqual(try rgbaPixels(from: unchanged), try rgbaPixels(from: rawImage))
        XCTAssertThrowsError(
            try RegistrationWorkerService.sourceRaster(
                rawImage,
                undoingCanonicalRotationDegrees: 90
            )
        )
    }

    func testBridgedNeighboringSectionsAreRecoveredAsTwoComponents() throws {
        let image = try makeWarmImage(width: 620, height: 260) { context in
            context.fillEllipse(in: CGRect(x: 42, y: 55, width: 230, height: 150))
            context.fillEllipse(in: CGRect(x: 348, y: 55, width: 230, height: 150))
            context.fill(CGRect(x: 270, y: 128, width: 80, height: 3))
        }

        let result = ImageProcessingService.detectTissueComponents(in: image)

        XCTAssertEqual(result.accepted.count, 2)
        XCTAssertTrue(result.accepted.allSatisfy {
            $0.isPlausibleCoronalSection(in: PixelSize(width: image.width, height: image.height))
        })
    }

    func testSelectedComponentDomainRemovesNeighborContamination() throws {
        let image = try makeWarmImage(width: 520, height: 220) { context in
            context.fillEllipse(in: CGRect(x: 24, y: 35, width: 210, height: 145))
            context.fillEllipse(in: CGRect(x: 286, y: 35, width: 210, height: 145))
        }
        let selected = TissueComponent(
            bounds: CGRect(x: 24, y: 35, width: 210, height: 145),
            area: 23_000
        )

        let processed = try XCTUnwrap(
            ImageProcessingService.makeTransparentTexture(from: image, sourceComponent: selected)
        )

        XCTAssertLessThanOrEqual(processed.signal.tissueBounds.maxX, selected.bounds.maxX + 4)
    }

    func testRegistrationSelectionDomainRetainsDimInteriorAndExcludesNeighbor() throws {
        let (source, displayed) = try makeDimRegistrationFixture()
        let ownership = try makeDimSelectionOwnership(from: source)
        let mask = try XCTUnwrap(ownership.mask(
            for: 0, cropRect: CGRect(x: 0, y: 0, width: 520, height: 220),
            outputImageSize: PixelSize(width: 520, height: 220)
        ))
        let domain = try rgbaPixels(from: mask)
        let displayAlpha = try alphaPixels(from: displayed.image)
        let original = try rgbaPixels(from: source)
        let dimPixel = 110 * 520 + 120
        XCTAssertEqual(displayAlpha[dimPixel], 0, "The visual alpha threshold rejects this dim patch")
        XCTAssertGreaterThan(original[dimPixel * 4], 0)
        XCTAssertEqual(domain[dimPixel * 4], 255, "Selection must retain dim interior anatomy")
        XCTAssertEqual(domain[(110 * 520 + 390) * 4], 0, "The neighboring section is outside this assignment")

        let scaled = try XCTUnwrap(ownership.mask(
            for: 0, cropRect: CGRect(x: 0, y: 0, width: 520, height: 220),
            outputImageSize: PixelSize(width: 260, height: 110)
        ))
        let scaledPixels = try rgbaPixels(from: scaled)
        XCTAssertEqual(scaledPixels[(55 * 260 + 60) * 4], 255)
        XCTAssertEqual(scaledPixels[(55 * 260 + 195) * 4], 0)
    }

    func testMaterializationPreservesChannelPixelsAndRawSelectionBoundsAfter180Degrees() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("raw-registration-input-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let (source, displayed) = try makeDimRegistrationFixture()
        var slice = makeSlice(index: 0, texture: displayed, sceneWidth: 1,
                              physicalWidth: 520, physicalHeight: 220)
        slice.rotationDegrees = 180
        slice.texture = try XCTUnwrap(ImageProcessingService.rotated180(displayed.image))
        let canonical = try XCTUnwrap(ImageProcessingService.rotated180(source))
        let ownership = try makeDimSelectionOwnership(from: source)
        let selectionMask = ownership.mask(
            for: 0, cropRect: CGRect(x: 0, y: 0, width: 520, height: 220),
            outputImageSize: PixelSize(width: 520, height: 220)
        )
        let seedMask = ownership.mask(
            for: 0, cropRect: CGRect(x: 0, y: 0, width: 520, height: 220),
            outputImageSize: PixelSize(width: 520, height: 220), seedsOnly: true
        )
        slice.channelImages = [2, 3].map { channel in
            VolumeChannelImage(channelIndex: channel, name: "Channel \(channel)",
                               pseudoColor: nil, sourceURL: slice.sourceURL, texture: canonical,
                               registrationSelectionMask: selectionMask, registrationSeedMask: seedMask)
        }
        let bounds = slice.signal.tissueBounds
        slice.signal.tissueBounds = CGRect(x: 520 - bounds.maxX, y: 220 - bounds.maxY,
                                          width: bounds.width, height: bounds.height)
        let volume = BrainVolume(
            sourceMode: .montageSections, slices: [slice], bounds: SIMD3<Double>(1, 1, 1),
            atlasRegistration: .empty, cortexRegistration: .empty,
            buildSummary: VolumeBuildSummary(sourceImages: 1, producedSlices: 1, rejectedComponents: 0,
                                            maxTexturePixels: 520, meanForegroundConfidence: 1,
                                            meanBackgroundRemoved: 0),
            reliabilityReport: .empty
        )
        let worker = RegistrationWorkerService()
        let project = worker.makeProject(
            dataset: BrainDataset(rootURL: folder.appendingPathComponent("data"), groups: []),
            volume: volume,
            channelMappings: [
                RegistrationChannelMapping(channelIndex: 2, name: "Structural", role: .structural, pseudoColor: nil),
                RegistrationChannelMapping(channelIndex: 3, name: "Probe", role: .probeTrack, pseudoColor: nil)
            ]
        )
        let materialized = try worker.materializeSliceRasters(project: project, volume: volume, outputURL: folder)
        let artifacts = try XCTUnwrap(materialized.slices.first?.artifacts)
        let structural = try XCTUnwrap(NSImage(contentsOfFile: try XCTUnwrap(artifacts.structuralImagePath)))
        let probe = try XCTUnwrap(NSImage(contentsOfFile: try XCTUnwrap(artifacts.probeChannelImagePath)))
        let mask = try XCTUnwrap(NSImage(contentsOfFile: try XCTUnwrap(artifacts.selectionMaskPath)))
        XCTAssertEqual(try rgbaPixels(from: structural), try rgbaPixels(from: source))
        XCTAssertEqual(try rgbaPixels(from: probe), try rgbaPixels(from: source))
        let domain = try rgbaPixels(from: mask)
        XCTAssertEqual(domain[(110 * 520 + 120) * 4], 255)
        XCTAssertEqual(domain[(110 * 520 + 390) * 4], 0, "Raw component bounds must not rotate twice")
        XCTAssertNil(artifacts.tissueMaskPath, "Selection and tissue segmentation are separate artifacts")
        let decoded = try JSONDecoder().decode(RegistrationArtifacts.self, from: JSONEncoder().encode(artifacts))
        XCTAssertEqual(decoded.selectionMaskPath, artifacts.selectionMaskPath)
    }

    func testMontageOwnershipPreservesSeedsAndSeparatesOverlappingSectionDomains() throws {
        let width = 100
        let height = 80
        let leftSeeds = (12..<63).flatMap { y in
            (12..<63).compactMap { x in (x < 23 || y < 23) ? y * width + x : nil }
        }
        let rightSeeds = (20..<71).flatMap { y in
            (40..<91).compactMap { x in (x >= 80 || y >= 60) ? y * width + x : nil }
        }
        let components = [
            TissueComponent(bounds: CGRect(x: 12, y: 12, width: 51, height: 51),
                            area: leftSeeds.count, seedPixelIndices: leftSeeds),
            TissueComponent(bounds: CGRect(x: 40, y: 20, width: 51, height: 51),
                            area: rightSeeds.count, seedPixelIndices: rightSeeds)
        ]
        XCTAssertFalse(components[0].bounds.intersection(components[1].bounds).isEmpty)
        let ownership = ImageProcessingService.registrationSelectionOwnership(
            components: components, imageSize: PixelSize(width: width, height: height)
        )
        var membershipCounts = [Int](repeating: 0, count: width * height)
        for (index, component) in components.enumerated() {
            let crop = component.bounds.insetBy(dx: -2, dy: -2)
            let mask = try XCTUnwrap(ownership.mask(
                for: index, cropRect: crop,
                outputImageSize: PixelSize(width: Int(crop.width), height: Int(crop.height))
            ))
            let pixels = try rgbaPixels(from: mask)
            for y in 0..<Int(crop.height) {
                for x in 0..<Int(crop.width) where pixels[(y * Int(crop.width) + x) * 4] > 0 {
                    membershipCounts[(Int(crop.minY) + y) * width + Int(crop.minX) + x] += 1
                }
            }
            for pixel in component.seedPixelIndices {
                XCTAssertEqual(ownership.owners[pixel], Int32(index))
                XCTAssertEqual(membershipCounts[pixel], 1)
            }
        }
        XCTAssertLessThanOrEqual(membershipCounts.max() ?? 0, 1, "No source pixel may enter two section domains")
        XCTAssertEqual(ownership.owners[35 * width + 30], 0, "Dim interior must remain assigned")
        XCTAssertGreaterThan(membershipCounts.filter { $0 == 1 }.count, leftSeeds.count + rightSeeds.count)
        let repeated = ImageProcessingService.registrationSelectionOwnership(
            components: components, imageSize: PixelSize(width: width, height: height)
        )
        XCTAssertEqual(repeated.owners, ownership.owners, "Tie resolution must be deterministic")
    }

    private func makeDimSelectionOwnership(from source: NSImage) throws -> RegistrationSelectionOwnership {
        var rect = NSRect(origin: .zero, size: source.size)
        let image = try XCTUnwrap(source.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let components = ImageProcessingService.detectTissueComponents(in: image)
        XCTAssertEqual(components.accepted.count, 2)
        for component in components.accepted {
            XCTAssertEqual(component.seedPixelIndices.count, component.area)
        }
        return ImageProcessingService.registrationSelectionOwnership(
            components: components.accepted, imageSize: PixelSize(width: image.width, height: image.height)
        )
    }

    private func makeDimRegistrationFixture() throws -> (NSImage, ProcessedTexture) {
        let image = try makeWarmImage(width: 520, height: 220) { context in
            context.fillEllipse(in: CGRect(x: 24, y: 35, width: 210, height: 145))
            context.fillEllipse(in: CGRect(x: 286, y: 35, width: 210, height: 145))
            context.setFillColor(CGColor(red: 0.18, green: 0.07, blue: 0, alpha: 1))
            context.fill(CGRect(x: 90, y: 85, width: 60, height: 50))
        }
        let selected = TissueComponent(bounds: CGRect(x: 24, y: 35, width: 210, height: 145), area: 23_000)
        let displayed = try XCTUnwrap(ImageProcessingService.makeTransparentTexture(from: image, sourceComponent: selected))
        return (NSImage(cgImage: image, size: NSSize(width: 520, height: 220)), displayed)
    }

    func testBilateralSymmetryMeasuresTheMaskInsteadOfItsBoundingBox() throws {
        let symmetric = try makeWarmImage(width: 320, height: 220) { context in
            context.fillEllipse(in: CGRect(x: 40, y: 35, width: 240, height: 150))
        }
        let asymmetric = try makeWarmImage(width: 320, height: 220) { context in
            context.fillEllipse(in: CGRect(x: 40, y: 35, width: 240, height: 150))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 42, y: 35, width: 84, height: 82))
        }
        let symmetricTexture = try XCTUnwrap(ImageProcessingService.makeTransparentTexture(from: symmetric))
        let asymmetricTexture = try XCTUnwrap(ImageProcessingService.makeTransparentTexture(from: asymmetric))

        let symmetricScore = ImageProcessingService.bilateralAlphaSymmetry(symmetricTexture.image)
        let asymmetricScore = ImageProcessingService.bilateralAlphaSymmetry(asymmetricTexture.image)

        XCTAssertGreaterThan(symmetricScore, 0.95)
        XCTAssertLessThan(asymmetricScore, symmetricScore - 0.10)
    }

    func testRealMontageFixtureRecoversAllTwentyFourSections() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("data", isDirectory: true)
        let relativePaths = [
            "XY01/Untitled_Overlay.tif",
            "XY02/Untitled_Overlay.tif",
            "XY03/Untitled2_Overlay.tif",
            "XY04/Untitled3_Overlay.tif"
        ]
        let urls = relativePaths.map { root.appendingPathComponent($0) }
        guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw XCTSkip("Real montage fixture is not present in this checkout.")
        }

        let counts = try urls.map { url in
            let image = try XCTUnwrap(ImageProcessingService.loadThumbnail(url: url, maxPixelSize: 1_400))
            return ImageProcessingService.detectTissueComponents(in: image).accepted.count
        }

        XCTAssertEqual(counts, [9, 3, 6, 6])
        XCTAssertEqual(counts.reduce(0, +), 24)
    }

    func testCalibratedTaperSurvivesPreviewRegistration() throws {
        let physicalWidths = [4_000.0, 6_000.0, 8_000.0, 6_000.0, 4_000.0]
        let texture = try makeSectionTexture()
        let slices = physicalWidths.enumerated().map { index, width in
            makeSlice(
                index: index,
                texture: texture,
                sceneWidth: 1,
                physicalWidth: width,
                physicalHeight: 3_000
            )
        }

        let atlas = AtlasRegistrationService().register(slices, mode: .montageSections)
        let cortex = CortexRegistrationService().register(atlas.slices, mode: .montageSections)

        let expected = physicalWidths.map { $0 / 6_000.0 }
        XCTAssertEqual(cortex.slices.count, expected.count)
        for (slice, expectedWidth) in zip(cortex.slices, expected) {
            XCTAssertEqual(slice.width, expectedWidth, accuracy: 0.000_001)
        }
    }

    func testContourLoftIsClosedManifoldAndPreservesTaper() throws {
        let texture = try makeSectionTexture()
        let sceneWidths = [0.60, 0.85, 1.20, 0.85, 0.60]
        let slices = sceneWidths.enumerated().map { index, width in
            makeSlice(
                index: index,
                texture: texture,
                sceneWidth: width,
                physicalWidth: width * 1_000,
                physicalHeight: 600
            )
        }
        let sampleCount = 64
        let mesh = try XCTUnwrap(
            TissueSurfaceMeshBuilder.build(slices: slices, samplesPerRing: sampleCount)
        )

        XCTAssertEqual(mesh.vertices.count, slices.count * sampleCount)
        XCTAssertEqual(
            mesh.triangleCount,
            (slices.count - 1) * sampleCount * 2 + (sampleCount - 2) * 2
        )
        XCTAssertTrue(mesh.vertices.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        XCTAssertTrue(mesh.normals.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })

        var edgeDegree: [UndirectedEdge: Int] = [:]
        var referencedVertices = Set<UInt32>()
        for start in stride(from: 0, to: mesh.triangleIndices.count, by: 3) {
            let triangle = [
                mesh.triangleIndices[start],
                mesh.triangleIndices[start + 1],
                mesh.triangleIndices[start + 2]
            ]
            XCTAssertEqual(Set(triangle).count, 3)
            referencedVertices.formUnion(triangle)
            let a = mesh.vertices[Int(triangle[0])]
            let b = mesh.vertices[Int(triangle[1])]
            let c = mesh.vertices[Int(triangle[2])]
            XCTAssertGreaterThan(simd_length(simd_cross(b - a, c - a)), 0.000_000_1)
            for edge in [
                UndirectedEdge(triangle[0], triangle[1]),
                UndirectedEdge(triangle[1], triangle[2]),
                UndirectedEdge(triangle[2], triangle[0])
            ] {
                edgeDegree[edge, default: 0] += 1
            }
        }
        XCTAssertTrue(edgeDegree.values.allSatisfy { $0 == 2 })
        XCTAssertEqual(referencedVertices.count, mesh.vertices.count)
        XCTAssertEqual(mesh.vertices.count - edgeDegree.count + mesh.triangleCount, 2)

        let recoveredWidths = slices.indices.map { ringIndex -> Float in
            let ring = mesh.vertices[(ringIndex * sampleCount)..<((ringIndex + 1) * sampleCount)]
            let xs = ring.map(\.x)
            return (xs.max() ?? 0) - (xs.min() ?? 0)
        }
        XCTAssertGreaterThan(recoveredWidths[2], recoveredWidths[1])
        XCTAssertGreaterThan(recoveredWidths[1], recoveredWidths[0])
        XCTAssertEqual(recoveredWidths[0], recoveredWidths[4], accuracy: 0.01)
    }

    func testConcaveOuterBoundaryPreservesObservedSilhouette() throws {
        let texture = try makeConcaveSectionTexture(notchOffset: 0)
        let slices = [0, 1].map { index in
            makeSlice(
                index: index,
                texture: texture,
                sceneWidth: 1,
                physicalWidth: 7_000,
                physicalHeight: 4_500
            )
        }
        let sampleCount = 128
        let mesh = try XCTUnwrap(
            TissueSurfaceMeshBuilder.build(slices: slices, samplesPerRing: sampleCount)
        )
        let observedRing = Array(mesh.vertices.prefix(sampleCount))

        let metrics = try silhouetteMetrics(ring: observedRing, slice: slices[0])

        XCTAssertGreaterThanOrEqual(metrics.iou, 0.95)
        XCTAssertEqual(metrics.areaRatio, 1, accuracy: 0.02)
    }

    func testPhaseAlignmentNeverMovesObservedRingsAndPreservesArea() throws {
        let textures = try [-24, 0, 22].map(makeConcaveSectionTexture(notchOffset:))
        let slices = textures.enumerated().map { index, texture in
            makeSlice(
                index: index,
                texture: texture,
                sceneWidth: 0.92 + Double(index) * 0.08,
                physicalWidth: 6_400 + Double(index) * 500,
                physicalHeight: 4_300
            )
        }
        let sampleCount = 128
        let mesh = try XCTUnwrap(
            TissueSurfaceMeshBuilder.build(slices: slices, samplesPerRing: sampleCount)
        )

        for (ringIndex, slice) in slices.enumerated() {
            let expected = try XCTUnwrap(
                TissueSurfaceMeshBuilder.sampledContourPoints(
                    for: slice,
                    samplesPerRing: sampleCount
                )
            )
            let start = ringIndex * sampleCount
            let actual = Array(mesh.vertices[start..<(start + sampleCount)])
            let maximumMovement = minimumCyclicMaximumDistance(expected, actual)
            let metrics = try silhouetteMetrics(ring: actual, slice: slice)

            XCTAssertLessThanOrEqual(maximumMovement, 0.000_000_1)
            XCTAssertEqual(polygonArea(actual), polygonArea(expected), accuracy: 0.000_000_1)
            XCTAssertEqual(metrics.areaRatio, 1, accuracy: 0.02)
        }
    }

    private struct UndirectedEdge: Hashable {
        var first: UInt32
        var second: UInt32

        init(_ a: UInt32, _ b: UInt32) {
            first = min(a, b)
            second = max(a, b)
        }
    }

    private func makeSlice(
        index: Int,
        texture: ProcessedTexture,
        sceneWidth: Double,
        physicalWidth: Double,
        physicalHeight: Double
    ) -> VolumeSlice {
        VolumeSlice(
            id: "slice-\(index)",
            title: String(format: "Slice %02d", index),
            sourceURL: URL(fileURLWithPath: "/tmp/slice-\(index).tif"),
            groupID: "XY01",
            texture: texture.image,
            width: sceneWidth,
            height: 0.60,
            z: Double(index) * 0.2,
            offsetX: 0,
            offsetY: 0,
            opacity: 0.6,
            signal: texture.signal,
            registration: .unregistered,
            cortex: .unregistered,
            physicalWidthMicrons: physicalWidth,
            physicalHeightMicrons: physicalHeight
        )
    }

    private func makeSectionTexture() throws -> ProcessedTexture {
        let image = try makeWarmImage(width: 260, height: 180) { context in
            context.fillEllipse(in: CGRect(x: 20, y: 18, width: 220, height: 144))
        }
        return try XCTUnwrap(ImageProcessingService.makeTransparentTexture(from: image))
    }

    private func makeConcaveSectionTexture(notchOffset: Int) throws -> ProcessedTexture {
        let image = try makeWarmImage(width: 320, height: 240) { context in
            context.fillEllipse(in: CGRect(x: 24, y: 20, width: 272, height: 200))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(
                CGRect(
                    x: 133 + notchOffset,
                    y: 116,
                    width: 54,
                    height: 124
                )
            )
        }
        return try XCTUnwrap(ImageProcessingService.makeTransparentTexture(from: image))
    }

    private func silhouetteMetrics(
        ring: [SIMD3<Float>],
        slice: VolumeSlice
    ) throws -> (iou: Double, areaRatio: Double) {
        let alpha = try alphaPixels(from: slice.texture)
        let width = slice.signal.imageSize.width
        let height = slice.signal.imageSize.height
        let polygon = ring.map { point in
            CGPoint(
                x: ((Double(point.x) - slice.offsetX) / slice.width + 0.5) * Double(width),
                y: (0.5 - (Double(point.y) - slice.offsetY) / slice.height) * Double(height)
            )
        }
        var truthCount = 0
        var predictedCount = 0
        var intersectionCount = 0
        var unionCount = 0

        for y in 0..<height {
            for x in 0..<width {
                let truth = alpha[y * width + x] > 20
                let predicted = polygonContains(
                    CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5),
                    polygon: polygon
                )
                if truth { truthCount += 1 }
                if predicted { predictedCount += 1 }
                if truth && predicted { intersectionCount += 1 }
                if truth || predicted { unionCount += 1 }
            }
        }

        return (
            iou: Double(intersectionCount) / Double(max(1, unionCount)),
            areaRatio: Double(predictedCount) / Double(max(1, truthCount))
        )
    }

    private func polygonContains(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
        var inside = false
        for index in polygon.indices {
            let current = polygon[index]
            let next = polygon[(index + 1) % polygon.count]
            guard (current.y > point.y) != (next.y > point.y) else { continue }
            let crossingX = current.x
                + (point.y - current.y) * (next.x - current.x) / (next.y - current.y)
            if point.x < crossingX {
                inside.toggle()
            }
        }
        return inside
    }

    private func minimumCyclicMaximumDistance(
        _ expected: [SIMD3<Float>],
        _ actual: [SIMD3<Float>]
    ) -> Float {
        guard expected.count == actual.count, !expected.isEmpty else { return .infinity }
        return expected.indices.map { shift in
            expected.indices.map { index in
                simd_distance(expected[index], actual[(index + shift) % actual.count])
            }.max() ?? .infinity
        }.min() ?? .infinity
    }

    private func polygonArea(_ points: [SIMD3<Float>]) -> Double {
        abs(points.indices.reduce(0.0) { partial, index in
            let current = points[index]
            let next = points[(index + 1) % points.count]
            return partial + Double(current.x * next.y - next.x * current.y)
        }) / 2
    }

    private func makeWarmImage(
        width: Int,
        height: Int,
        draw: (CGContext) -> Void
    ) throws -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.92, green: 0.48, blue: 0.12, alpha: 1))
        draw(context)
        return try XCTUnwrap(context.makeImage())
    }

    private func alphaPixels(from image: NSImage) throws -> [UInt8] {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        let cgImage = try XCTUnwrap(
            image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
        )
        var rgba = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &rgba,
                width: cgImage.width,
                height: cgImage.height,
                bitsPerComponent: 8,
                bytesPerRow: cgImage.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] }
    }

    private func rgbaPixels(from image: NSImage) throws -> [UInt8] {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        let cgImage = try XCTUnwrap(
            image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
        )
        var rgba = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &rgba,
                width: cgImage.width,
                height: cgImage.height,
                bitsPerComponent: 8,
                bytesPerRow: cgImage.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return rgba
    }
}
