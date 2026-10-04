import CoreGraphics
import Foundation
import ImageIO

struct AllenAtlasStructure: Identifiable, Hashable, Sendable {
    var id: Int
    var acronym: String
    var name: String
    var structureIDPath: [Int]
    var rgbTriplet: [Int]
}

struct AllenAtlasStructureCatalog: Sendable {
    private var structuresByID: [Int: AllenAtlasStructure]

    init(contentsOf url: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw AtlasRegionLookupError.couldNotReadStructures(url, error.localizedDescription)
        }

        let decoder = JSONDecoder()
        let structures: [AllenAtlasStructure]
        if let records = try? decoder.decode([BrainGlobeStructureRecord].self, from: data) {
            structures = records.map(\.structure)
        } else if let payload = try? decoder.decode(PortableOntologyPayload.self, from: data) {
            structures = payload.structures.map(\.structure)
        } else {
            throw AtlasRegionLookupError.invalidStructures(
                "Expected a BrainGlobe structure array or an exported ontology payload."
            )
        }

        guard !structures.isEmpty else {
            throw AtlasRegionLookupError.invalidStructures("The atlas ontology contains no structures.")
        }

        var lookup: [Int: AllenAtlasStructure] = [:]
        lookup.reserveCapacity(structures.count)
        for structure in structures {
            guard structure.id > 0,
                  !structure.acronym.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !structure.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  structure.rgbTriplet.count == 3,
                  structure.rgbTriplet.allSatisfy({ (0...255).contains($0) }) else {
                throw AtlasRegionLookupError.invalidStructures(
                    "Structure \(structure.id) has invalid identity, name, or RGB metadata."
                )
            }
            guard lookup.updateValue(structure, forKey: structure.id) == nil else {
                throw AtlasRegionLookupError.invalidStructures(
                    "The atlas ontology contains duplicate structure ID \(structure.id)."
                )
            }
        }
        structuresByID = lookup
    }

    func structure(for id: UInt32) -> AllenAtlasStructure? {
        structuresByID[Int(id)]
    }

    func ancestry(for structure: AllenAtlasStructure) -> [AllenAtlasStructure] {
        let resolved = structure.structureIDPath.compactMap { structuresByID[$0] }
        if resolved.last?.id == structure.id {
            return resolved
        }
        return resolved + [structure]
    }
}

struct AtlasAnnotationRaster: Sendable {
    let width: Int
    let height: Int
    private let structureIDs: [UInt32]

    init(contentsOf url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AtlasRegionLookupError.couldNotReadAnnotation(url)
        }
        try self.init(image: image)
    }

    init(image: CGImage) throws {
        guard image.width > 0, image.height > 0,
              image.bitsPerComponent == 32,
              image.bitsPerPixel == 32,
              image.colorSpace?.model == .monochrome else {
            throw AtlasRegionLookupError.invalidAnnotation(
                "Expected a non-empty 32-bit grayscale integer annotation image."
            )
        }
        guard image.bytesPerRow >= image.width * MemoryLayout<UInt32>.size,
              let providerData = image.dataProvider?.data else {
            throw AtlasRegionLookupError.invalidAnnotation("The annotation pixel buffer is unavailable.")
        }

        let data = providerData as Data
        guard data.count >= image.bytesPerRow * image.height else {
            throw AtlasRegionLookupError.invalidAnnotation("The annotation pixel buffer is truncated.")
        }

        let byteOrder = image.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue
        let isBigEndian: Bool
        switch byteOrder {
        case CGBitmapInfo.byteOrder32Big.rawValue:
            isBigEndian = true
        case CGBitmapInfo.byteOrder32Little.rawValue, CGBitmapInfo.byteOrderDefault.rawValue:
            isBigEndian = false
        default:
            throw AtlasRegionLookupError.invalidAnnotation("The annotation byte order is unsupported.")
        }

        var values: [UInt32] = []
        values.reserveCapacity(image.width * image.height)
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            for y in 0..<image.height {
                let row = baseAddress.advanced(by: y * image.bytesPerRow)
                for x in 0..<image.width {
                    let pixel = row.advanced(by: x * MemoryLayout<UInt32>.size)
                    if isBigEndian {
                        values.append(
                            UInt32(pixel[3])
                                | UInt32(pixel[2]) << 8
                                | UInt32(pixel[1]) << 16
                                | UInt32(pixel[0]) << 24
                        )
                    } else {
                        values.append(
                            UInt32(pixel[0])
                                | UInt32(pixel[1]) << 8
                                | UInt32(pixel[2]) << 16
                                | UInt32(pixel[3]) << 24
                        )
                    }
                }
            }
        }
        guard values.count == image.width * image.height else {
            throw AtlasRegionLookupError.invalidAnnotation("The annotation pixels could not be decoded.")
        }

        width = image.width
        height = image.height
        structureIDs = values
    }

    func structureID(x: Int, y: Int) -> UInt32? {
        guard (0..<width).contains(x), (0..<height).contains(y) else {
            return nil
        }
        return structureIDs[y * width + x]
    }
}

struct AtlasRegionHit: Hashable, Sendable {
    var structureID: UInt32
    var acronym: String
    var name: String
    var rgbTriplet: [Int]
    var ancestry: [AllenAtlasStructure]
    var annotationX: Int
    var annotationY: Int
    var isKnownStructure: Bool

    var hierarchyDescription: String? {
        let omittedAcronyms: Set<String> = ["root", "grey", "CH", "CTXpl"]
        let names = ancestry
            .dropLast()
            .filter { !omittedAcronyms.contains($0.acronym) }
            .map(\.name)
        return names.isEmpty ? nil : names.joined(separator: " › ")
    }
}

struct AtlasRegionLookup: Sendable {
    let annotation: AtlasAnnotationRaster
    let catalog: AllenAtlasStructureCatalog

    init(annotationURL: URL, structuresURL: URL) throws {
        annotation = try AtlasAnnotationRaster(contentsOf: annotationURL)
        catalog = try AllenAtlasStructureCatalog(contentsOf: structuresURL)
    }

    func region(x: Int, y: Int) -> AtlasRegionHit? {
        guard let structureID = annotation.structureID(x: x, y: y) else {
            return nil
        }
        if structureID == 0 {
            return AtlasRegionHit(
                structureID: 0,
                acronym: "outside",
                name: "Outside atlas",
                rgbTriplet: [120, 120, 120],
                ancestry: [],
                annotationX: x,
                annotationY: y,
                isKnownStructure: true
            )
        }
        guard let structure = catalog.structure(for: structureID) else {
            return AtlasRegionHit(
                structureID: structureID,
                acronym: "ID \(structureID)",
                name: "Unknown Allen structure",
                rgbTriplet: [170, 170, 170],
                ancestry: [],
                annotationX: x,
                annotationY: y,
                isKnownStructure: false
            )
        }
        return AtlasRegionHit(
            structureID: structureID,
            acronym: structure.acronym,
            name: structure.name,
            rgbTriplet: structure.rgbTriplet,
            ancestry: catalog.ancestry(for: structure),
            annotationX: x,
            annotationY: y,
            isKnownStructure: true
        )
    }
}

enum AtlasImageGeometry {
    static func aspectFitRect(imageSize: CGSize, containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else {
            return .zero
        }
        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let fittedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (containerSize.width - fittedSize.width) / 2,
            y: (containerSize.height - fittedSize.height) / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    static func annotationPixel(
        at location: CGPoint,
        imageSize: CGSize,
        containerSize: CGSize
    ) -> (x: Int, y: Int)? {
        let fitted = aspectFitRect(imageSize: imageSize, containerSize: containerSize)
        guard !fitted.isEmpty,
              location.x >= fitted.minX, location.x < fitted.maxX,
              location.y >= fitted.minY, location.y < fitted.maxY else {
            return nil
        }
        let normalizedX = (location.x - fitted.minX) / fitted.width
        let normalizedY = (location.y - fitted.minY) / fitted.height
        let x = min(Int(imageSize.width) - 1, max(0, Int(floor(normalizedX * imageSize.width))))
        let y = min(Int(imageSize.height) - 1, max(0, Int(floor(normalizedY * imageSize.height))))
        return (x, y)
    }

    static func containerPoint(
        annotationX: Int,
        annotationY: Int,
        imageSize: CGSize,
        containerSize: CGSize
    ) -> CGPoint? {
        guard annotationX >= 0, annotationY >= 0,
              annotationX < Int(imageSize.width), annotationY < Int(imageSize.height) else {
            return nil
        }
        let fitted = aspectFitRect(imageSize: imageSize, containerSize: containerSize)
        guard !fitted.isEmpty else { return nil }
        return CGPoint(
            x: fitted.minX + (CGFloat(annotationX) + 0.5) / imageSize.width * fitted.width,
            y: fitted.minY + (CGFloat(annotationY) + 0.5) / imageSize.height * fitted.height
        )
    }
}

enum AtlasRegionLookupError: LocalizedError {
    case couldNotReadStructures(URL, String)
    case invalidStructures(String)
    case couldNotReadAnnotation(URL)
    case invalidAnnotation(String)

    var errorDescription: String? {
        switch self {
        case .couldNotReadStructures(let url, let detail):
            "Could not read Allen structures at \(url.path): \(detail)"
        case .invalidStructures(let detail):
            "Invalid Allen structure hierarchy: \(detail)"
        case .couldNotReadAnnotation(let url):
            "Could not read atlas annotation IDs at \(url.path)."
        case .invalidAnnotation(let detail):
            "Invalid atlas annotation image: \(detail)"
        }
    }
}

private struct BrainGlobeStructureRecord: Decodable {
    var id: Int
    var acronym: String
    var name: String
    var structureIDPath: [Int]
    var rgbTriplet: [Int]

    enum CodingKeys: String, CodingKey {
        case id
        case acronym
        case name
        case structureIDPath = "structure_id_path"
        case rgbTriplet = "rgb_triplet"
    }

    var structure: AllenAtlasStructure {
        AllenAtlasStructure(
            id: id,
            acronym: acronym,
            name: name,
            structureIDPath: structureIDPath,
            rgbTriplet: rgbTriplet
        )
    }
}

private struct PortableOntologyPayload: Decodable {
    var structures: [PortableStructureRecord]
}

private struct PortableStructureRecord: Decodable {
    var id: Int
    var acronym: String
    var name: String
    var structureIDPath: [Int]
    var rgbTriplet: [Int]

    var structure: AllenAtlasStructure {
        AllenAtlasStructure(
            id: id,
            acronym: acronym,
            name: name,
            structureIDPath: structureIDPath,
            rgbTriplet: rgbTriplet
        )
    }
}
