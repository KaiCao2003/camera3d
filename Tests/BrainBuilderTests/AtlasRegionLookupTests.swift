import CoreGraphics
import XCTest
@testable import BrainBuilder

final class AtlasRegionLookupTests: XCTestCase {
    func testBrainGlobeOntologyAndUInt32AnnotationResolveExactRegionNames() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let structuresURL = folder.appendingPathComponent("structures.json")
        let annotationURL = folder.appendingPathComponent("annotation-ids.tif")
        try brainGlobeStructuresJSON.write(to: structuresURL, atomically: true, encoding: .utf8)
        try XCTUnwrap(Data(base64Encoded: uint32AnnotationTIFFBase64)).write(to: annotationURL)

        let lookup = try AtlasRegionLookup(
            annotationURL: annotationURL,
            structuresURL: structuresURL
        )

        let outside = try XCTUnwrap(lookup.region(x: 0, y: 0))
        XCTAssertEqual(outside.structureID, 0)
        XCTAssertEqual(outside.name, "Outside atlas")

        let visual = try XCTUnwrap(lookup.region(x: 1, y: 0))
        XCTAssertEqual(visual.structureID, 821)
        XCTAssertEqual(visual.acronym, "VISp2/3")
        XCTAssertEqual(visual.name, "Primary visual area, layer 2/3")
        XCTAssertEqual(
            visual.hierarchyDescription,
            "Cerebral cortex › Isocortex › Visual areas › Primary visual area"
        )
        XCTAssertEqual(visual.rgbTriplet, [8, 133, 140])

        let unknown = try XCTUnwrap(lookup.region(x: 0, y: 1))
        XCTAssertEqual(unknown.structureID, 607_344_858)
        XCTAssertEqual(unknown.acronym, "ID 607344858")
        XCTAssertEqual(unknown.name, "Unknown Allen structure")
        XCTAssertFalse(unknown.isKnownStructure)

        let ca1 = try XCTUnwrap(lookup.region(x: 1, y: 1))
        XCTAssertEqual(ca1.acronym, "CA1")
        XCTAssertEqual(ca1.name, "Field CA1")
    }

    func testAnnotationRasterPreservesThirtyTwoBitBigEndianIDsAndBounds() throws {
        let image = try annotationImage(
            values: [1, 382, 484_682_470, UInt32.max],
            width: 2,
            height: 2,
            byteOrder: .byteOrder32Big
        )
        let raster = try AtlasAnnotationRaster(image: image)

        XCTAssertEqual(raster.width, 2)
        XCTAssertEqual(raster.height, 2)
        XCTAssertEqual(raster.structureID(x: 0, y: 0), 1)
        XCTAssertEqual(raster.structureID(x: 1, y: 0), 382)
        XCTAssertEqual(raster.structureID(x: 0, y: 1), 484_682_470)
        XCTAssertEqual(raster.structureID(x: 1, y: 1), UInt32.max)
        XCTAssertNil(raster.structureID(x: -1, y: 0))
        XCTAssertNil(raster.structureID(x: 2, y: 0))
        XCTAssertNil(raster.structureID(x: 0, y: 2))
    }

    func testAnnotationRasterRejectsDisplayImageInsteadOfIntegerLabelMap() throws {
        let pixels = Data([0, 64, 128, 255])
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(
            CGImage(
                width: 2,
                height: 2,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: 2,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        )

        XCTAssertThrowsError(try AtlasAnnotationRaster(image: image))
    }

    func testAspectFitCoordinateMappingExcludesLetterboxAndKeepsTopDownRows() throws {
        let imageSize = CGSize(width: 200, height: 100)
        let containerSize = CGSize(width: 100, height: 100)
        XCTAssertEqual(
            AtlasImageGeometry.aspectFitRect(imageSize: imageSize, containerSize: containerSize),
            CGRect(x: 0, y: 25, width: 100, height: 50)
        )

        XCTAssertNil(
            AtlasImageGeometry.annotationPixel(
                at: CGPoint(x: 50, y: 24.99),
                imageSize: imageSize,
                containerSize: containerSize
            )
        )
        XCTAssertEqual(
            AtlasImageGeometry.annotationPixel(
                at: CGPoint(x: 0, y: 25),
                imageSize: imageSize,
                containerSize: containerSize
            ).map { [$0.x, $0.y] },
            [0, 0]
        )
        XCTAssertEqual(
            AtlasImageGeometry.annotationPixel(
                at: CGPoint(x: 50, y: 50),
                imageSize: imageSize,
                containerSize: containerSize
            ).map { [$0.x, $0.y] },
            [100, 50]
        )
        XCTAssertEqual(
            AtlasImageGeometry.annotationPixel(
                at: CGPoint(x: 99.99, y: 74.99),
                imageSize: imageSize,
                containerSize: containerSize
            ).map { [$0.x, $0.y] },
            [199, 99]
        )
        XCTAssertNil(
            AtlasImageGeometry.annotationPixel(
                at: CGPoint(x: 100, y: 50),
                imageSize: imageSize,
                containerSize: containerSize
            )
        )

        let marker = try XCTUnwrap(
            AtlasImageGeometry.containerPoint(
                annotationX: 100,
                annotationY: 50,
                imageSize: imageSize,
                containerSize: containerSize
            )
        )
        XCTAssertEqual(marker.x, 50.25, accuracy: 0.000_001)
        XCTAssertEqual(marker.y, 50.25, accuracy: 0.000_001)
        XCTAssertEqual(
            AtlasImageGeometry.annotationPixel(
                at: marker,
                imageSize: imageSize,
                containerSize: containerSize
            ).map { [$0.x, $0.y] },
            [100, 50]
        )
        XCTAssertNil(
            AtlasImageGeometry.containerPoint(
                annotationX: 200,
                annotationY: 50,
                imageSize: imageSize,
                containerSize: containerSize
            )
        )
    }

    func testOntologyRejectsDuplicateStructureIDs() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let structuresURL = folder.appendingPathComponent("structures.json")
        try """
        [
          {"id": 42, "acronym": "A", "name": "First", "structure_id_path": [42], "rgb_triplet": [1, 2, 3]},
          {"id": 42, "acronym": "B", "name": "Second", "structure_id_path": [42], "rgb_triplet": [4, 5, 6]}
        ]
        """.write(to: structuresURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try AllenAtlasStructureCatalog(contentsOf: structuresURL))
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrainBuilderRegionLookupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func annotationImage(
        values: [UInt32],
        width: Int,
        height: Int,
        byteOrder: CGBitmapInfo
    ) throws -> CGImage {
        XCTAssertEqual(values.count, width * height)
        let bigEndian = byteOrder == .byteOrder32Big
        var bytes: [UInt8] = []
        bytes.reserveCapacity(values.count * MemoryLayout<UInt32>.size)
        for value in values {
            let littleEndianBytes = [
                UInt8(value & 0xFF),
                UInt8((value >> 8) & 0xFF),
                UInt8((value >> 16) & 0xFF),
                UInt8((value >> 24) & 0xFF)
            ]
            bytes.append(contentsOf: bigEndian ? littleEndianBytes.reversed() : littleEndianBytes)
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(
            CGImage(
                width: width,
                height: height,
                bitsPerComponent: 32,
                bitsPerPixel: 32,
                bytesPerRow: width * MemoryLayout<UInt32>.size,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: byteOrder,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        )
    }

    private var brainGlobeStructuresJSON: String {
        """
        [
          {"id": 997, "acronym": "root", "name": "root", "structure_id_path": [997], "rgb_triplet": [255, 255, 255]},
          {"id": 8, "acronym": "grey", "name": "Basic cell groups and regions", "structure_id_path": [997, 8], "rgb_triplet": [191, 218, 227]},
          {"id": 567, "acronym": "CH", "name": "Cerebrum", "structure_id_path": [997, 8, 567], "rgb_triplet": [176, 255, 184]},
          {"id": 688, "acronym": "CTX", "name": "Cerebral cortex", "structure_id_path": [997, 8, 567, 688], "rgb_triplet": [176, 255, 184]},
          {"id": 695, "acronym": "CTXpl", "name": "Cortical plate", "structure_id_path": [997, 8, 567, 688, 695], "rgb_triplet": [112, 255, 113]},
          {"id": 315, "acronym": "Isocortex", "name": "Isocortex", "structure_id_path": [997, 8, 567, 688, 695, 315], "rgb_triplet": [112, 255, 113]},
          {"id": 669, "acronym": "VIS", "name": "Visual areas", "structure_id_path": [997, 8, 567, 688, 695, 315, 669], "rgb_triplet": [8, 133, 140]},
          {"id": 385, "acronym": "VISp", "name": "Primary visual area", "structure_id_path": [997, 8, 567, 688, 695, 315, 669, 385], "rgb_triplet": [8, 133, 140]},
          {"id": 821, "acronym": "VISp2/3", "name": "Primary visual area, layer 2/3", "structure_id_path": [997, 8, 567, 688, 695, 315, 669, 385, 821], "rgb_triplet": [8, 133, 140]},
          {"id": 1089, "acronym": "HPF", "name": "Hippocampal formation", "structure_id_path": [997, 8, 567, 688, 695, 1089], "rgb_triplet": [126, 208, 75]},
          {"id": 1080, "acronym": "HIP", "name": "Hippocampal region", "structure_id_path": [997, 8, 567, 688, 695, 1089, 1080], "rgb_triplet": [126, 208, 75]},
          {"id": 375, "acronym": "CA", "name": "Ammon's horn", "structure_id_path": [997, 8, 567, 688, 695, 1089, 1080, 375], "rgb_triplet": [126, 208, 75]},
          {"id": 382, "acronym": "CA1", "name": "Field CA1", "structure_id_path": [997, 8, 567, 688, 695, 1089, 1080, 375, 382], "rgb_triplet": [126, 208, 75]}
        ]
        """
    }

    private var uint32AnnotationTIFFBase64: String {
        "SUkqAAgAAAAOAAABBAABAAAAAgAAAAEBBAABAAAAAgAAAAIBAwABAAAAIAAAAAMBAwABAAAAAQAAAAYBAwABAAAAAQAAAA4BAgASAAAAtgAAABEBBAABAAAAAAEAABUBAwABAAAAAQAAABYBBAABAAAAAgAAABcBBAABAAAAEAAAABoBBQABAAAA2AAAABsBBQABAAAA4AAAACgBAwABAAAAAQAAADEBAgAMAAAA6AAAAAAAAAB7InNoYXBlIjogWzIsIDJdfQAAAAAAAAAAAAAAAAAAAAAAAQAAAAEAAAABAAAAAQAAAHRpZmZmaWxlLnB5AAAAAAAAAAAAAAAAAAAAAAA1AwAA2lgzJH4BAAA="
    }
}
