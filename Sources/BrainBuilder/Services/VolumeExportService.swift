import AppKit
import Foundation

struct VolumeExportService {
    func export(volume: BrainVolume, dataset: BrainDataset, to folderURL: URL) throws -> VolumeExportResult {
        let fileManager = FileManager.default
        let texturesURL = folderURL.appendingPathComponent("textures", isDirectory: true)
        let actualSlicesURL = folderURL.appendingPathComponent("actual_slices", isDirectory: true)
        let masksURL = folderURL.appendingPathComponent("masks", isDirectory: true)
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)

        for directory in [texturesURL, actualSlicesURL, masksURL] {
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let objURL = folderURL.appendingPathComponent("brain_stack.obj")
        let mtlURL = folderURL.appendingPathComponent("brain_stack.mtl")
        let metadataURL = folderURL.appendingPathComponent("metadata.json")

        var obj = """
        # BrainBuilder 3D reconstruction
        # Source: \(dataset.rootURL.path)
        mtllib brain_stack.mtl

        """

        var mtl = "# BrainBuilder slice materials\n\n"
        var vertexIndex = 1
        var textureIndex = 1

        for (index, slice) in volume.slices.enumerated() {
            try Task.checkCancellation()

            let textureName = String(format: "slice_%04d.png", index + 1)
            let textureURL = texturesURL.appendingPathComponent(textureName)
            let actualSliceURL = actualSlicesURL.appendingPathComponent(textureName)
            let maskURL = masksURL.appendingPathComponent(String(format: "mask_%04d.png", index + 1))

            let cgImage = try cgImage(from: slice.texture, name: textureName)
            let textureData = try pngData(from: cgImage, name: textureName)
            try textureData.write(to: textureURL, options: .atomic)
            try textureData.write(to: actualSliceURL, options: .atomic)
            try maskPNGData(from: cgImage, name: maskURL.lastPathComponent).write(to: maskURL, options: .atomic)

            let materialName = String(format: "slice_%04d", index + 1)
            mtl += """
            newmtl \(materialName)
            Ka 1.000 1.000 1.000
            Kd 1.000 1.000 1.000
            d \(String(format: "%.4f", slice.opacity))
            illum 2
            map_Kd textures/\(textureName)

            """

            let x0 = slice.offsetX - slice.width / 2.0
            let x1 = slice.offsetX + slice.width / 2.0
            let y0 = slice.offsetY - slice.height / 2.0
            let y1 = slice.offsetY + slice.height / 2.0
            let z = slice.z

            obj += """
            o \(sanitizedObjectName(slice.title))
            v \(x0) \(y0) \(z)
            v \(x1) \(y0) \(z)
            v \(x1) \(y1) \(z)
            v \(x0) \(y1) \(z)
            vt 0 1
            vt 1 1
            vt 1 0
            vt 0 0
            usemtl \(materialName)
            f \(vertexIndex)/\(textureIndex) \(vertexIndex + 1)/\(textureIndex + 1) \(vertexIndex + 2)/\(textureIndex + 2) \(vertexIndex + 3)/\(textureIndex + 3)

            """

            vertexIndex += 4
            textureIndex += 4
        }

        appendTissueSurface(volume: volume, obj: &obj, mtl: &mtl, vertexIndex: &vertexIndex)

        try obj.write(to: objURL, atomically: true, encoding: .utf8)
        try mtl.write(to: mtlURL, atomically: true, encoding: .utf8)
        try writeMetadata(volume: volume, dataset: dataset, to: metadataURL)

        return VolumeExportResult(
            folderURL: folderURL,
            objURL: objURL,
            mtlURL: mtlURL,
            metadataURL: metadataURL,
            textureCount: volume.slices.count,
            actualSliceCount: volume.slices.count,
            maskCount: volume.slices.count
        )
    }

    private func cgImage(from image: NSImage, name: String) throws -> CGImage {
        var rect = NSRect(origin: .zero, size: image.size)
        if let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            return cgImage
        }

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let cgImage = bitmap.cgImage else {
            throw VolumeExportError.textureEncodingFailed(name)
        }
        return cgImage
    }

    private func pngData(from cgImage: CGImage, name: String) throws -> Data {
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw VolumeExportError.textureEncodingFailed(name)
        }
        return data
    }

    private func maskPNGData(from cgImage: CGImage, name: String) throws -> Data {
        let width = cgImage.width
        let height = cgImage.height
        let rgbaBytesPerRow = width * 4
        var rgba = [UInt8](repeating: 0, count: height * rgbaBytesPerRow)

        guard let context = CGContext(
            data: &rgba,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: rgbaBytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw VolumeExportError.textureEncodingFailed(name)
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var pixels = [UInt8](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            pixels[index] = rgba[index * 4 + 3] > 20 ? 255 : 0
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let mask = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw VolumeExportError.textureEncodingFailed(name)
        }

        let rep = NSBitmapImageRep(cgImage: mask)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw VolumeExportError.textureEncodingFailed(name)
        }
        return data
    }

    private func writeMetadata(volume: BrainVolume, dataset: BrainDataset, to url: URL) throws {
        let groups = dataset.groups.map { group -> [String: Any] in
            let metadata = group.metadata
            return [
                "id": group.id,
                "folder": group.folderURL.path,
                "lens": metadata.lensName,
                "originalImageSize": metadata.originalImageSize.map {
                    [
                        "width": $0.width,
                        "height": $0.height
                    ]
                } ?? NSNull(),
                "capturedChannels": metadata.capturedChannels.map { channel in
                    [
                        "index": channel.index,
                        "name": channel.name,
                        "pseudoColor": jsonValue(channel.pseudoColor),
                        "pixelMode": jsonValue(channel.pixelMode),
                        "exposureSeconds": jsonValue(channel.exposureSeconds)
                    ]
                }
            ]
        }

        let slices = volume.slices.map { slice -> [String: Any] in
            [
                "id": slice.id,
                "title": slice.title,
                "source": slice.sourceURL.path,
                "group": slice.groupID,
                "scene": [
                    "width": slice.width,
                    "height": slice.height,
                    "x": slice.offsetX,
                    "y": slice.offsetY,
                    "z": slice.z,
                    "opacity": slice.opacity
                ],
                "signal": [
                    "meanRed": slice.signal.redMean,
                    "meanGreen": slice.signal.greenMean,
                    "meanBlue": slice.signal.blueMean,
                    "coverage": slice.signal.alphaCoverage,
                    "foregroundConfidence": slice.signal.foregroundConfidence,
                    "backgroundSuppression": slice.signal.backgroundSuppression,
                    "componentAreaPixels": slice.signal.componentAreaPixels
                ],
                "registration": [
                    "method": slice.registration.method,
                    "orderIndex": slice.registration.orderIndex,
                    "atlasAPMicrons": slice.registration.atlasAPMicrons,
                    "atlasAPIndex10um": slice.registration.atlasAPIndex10um,
                    "atlasScale": slice.registration.atlasScale,
                    "atlasOffsetX": slice.registration.atlasOffsetX,
                    "atlasOffsetY": slice.registration.atlasOffsetY,
                    "confidence": slice.registration.confidence,
                    "atlasContourScore": slice.registration.atlasContourScore,
                    "atlasContourDeviation": slice.registration.atlasContourDeviation
                ],
                "cortexRegistration": [
                    "method": slice.cortex.method,
                    "midlineX": slice.cortex.midlineX,
                    "dorsalY": slice.cortex.dorsalY,
                    "leftCortexX": slice.cortex.leftCortexX,
                    "rightCortexX": slice.cortex.rightCortexX,
                    "cortexWidth": slice.cortex.cortexWidth,
                    "symmetryScore": slice.cortex.symmetryScore,
                    "confidence": slice.cortex.confidence
                ]
            ]
        }

        let payload: [String: Any] = [
            "format": "BrainBuilder Reconstruction",
            "sourceRoot": dataset.rootURL.path,
            "stackSourceMode": volume.sourceMode.rawValue,
            "limitations": [
                "Atlas fields in this OBJ preview are preliminary AP-prior and morphology-QC estimates, not registered atlas coordinates.",
                "This OBJ preview does not incorporate DeepSlice/QuickNII pose results or SimpleITK atlas-to-slice transforms from the Atlas workspace.",
                "Cortex geometry is estimated from foreground masks and must not be interpreted as Allen atlas cortex boundary alignment."
            ],
            "recommendedAtlasWorkflow": [
                "Use BrainBuilder's Atlas workspace (DeepSlice, BrainGlobe, and SimpleITK) or an independently validated equivalent before region-level quantification.",
                "Review the predicted slice plane and every affine overlay; pose estimates alone are not registrations.",
                "Use a validated external deformable workflow for sections that cannot be represented adequately by an affine transform.",
                "Accept reviewed slices, then export the self-contained atlas transform and annotation artifacts."
            ],
            "atlasRegistration": [
                "atlasName": volume.atlasRegistration.atlasName,
                "method": volume.atlasRegistration.method,
                "sliceCount": volume.atlasRegistration.sliceCount,
                "apRangeMicrons": [
                    volume.atlasRegistration.apRangeMicrons.lowerBound,
                    volume.atlasRegistration.apRangeMicrons.upperBound
                ],
                "meanConfidence": volume.atlasRegistration.meanConfidence,
                "meanContourScore": volume.atlasRegistration.meanContourScore,
                "meanContourDeviation": volume.atlasRegistration.meanContourDeviation
            ],
            "cortexRegistration": [
                "method": volume.cortexRegistration.method,
                "sliceCount": volume.cortexRegistration.sliceCount,
                "meanConfidence": volume.cortexRegistration.meanConfidence,
                "meanSymmetry": volume.cortexRegistration.meanSymmetry,
                "medianCortexWidth": volume.cortexRegistration.medianCortexWidth
            ],
            "buildSummary": [
                    "sourceImages": volume.buildSummary.sourceImages,
                    "producedSlices": volume.buildSummary.producedSlices,
                    "rejectedComponents": volume.buildSummary.rejectedComponents,
                    "maxTexturePixels": volume.buildSummary.maxTexturePixels,
                    "meanForegroundConfidence": volume.buildSummary.meanForegroundConfidence,
                    "meanBackgroundRemoved": volume.buildSummary.meanBackgroundRemoved
            ],
            "atlasQC": atlasQCPayload(volume.reliabilityReport),
            "artifacts": [
                "obj": "brain_stack.obj",
                "mtl": "brain_stack.mtl",
                "textures": "textures",
                "actualSlices": "actual_slices",
                "masks": "masks"
            ],
            "groups": groups,
            "slices": slices
        ]

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func jsonValue<T>(_ value: T?) -> Any {
        value ?? NSNull()
    }

    private func atlasQCPayload(_ report: ReliabilityReport) -> [String: Any] {
        [
            "score": report.score,
            "meaning": "Pre-registration QC only. This is not a measured Allen atlas alignment accuracy.",
            "level": report.level.rawValue,
            "atlasReference": [
                "summary": report.atlasReference.summary,
                "folder": jsonValue(report.atlasReference.folderURL?.path),
                "expectedFiles": report.atlasReference.expectedFiles,
                "presentFiles": report.atlasReference.presentFiles,
                "sizeMatchedFiles": report.atlasReference.sizeMatchedFiles
            ],
            "issues": report.issues.map { issue in
                [
                    "severity": issue.severity.rawValue,
                    "title": issue.title,
                    "detail": issue.detail
                ]
            }
        ]
    }

    private func sanitizedObjectName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        return value
            .unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "_" }
            .map(String.init)
            .joined()
    }

    private func appendTissueSurface(
        volume: BrainVolume,
        obj: inout String,
        mtl: inout String,
        vertexIndex: inout Int
    ) {
        guard let mesh = TissueSurfaceMeshBuilder.build(slices: volume.slices) else {
            return
        }

        mtl += """
        newmtl tissue_surface
        Ka 1.000 0.420 0.000
        Kd 1.000 0.420 0.000
        d 0.2800
        illum 2

        """

        obj += """
        o tissue_surface
        usemtl tissue_surface

        """

        let firstVertex = vertexIndex
        for vertex in mesh.vertices {
            obj += "v \(vertex.x) \(vertex.y) \(vertex.z)\n"
        }
        vertexIndex += mesh.vertices.count
        for triangleStart in stride(from: 0, to: mesh.triangleIndices.count, by: 3) {
            let a = firstVertex + Int(mesh.triangleIndices[triangleStart])
            let b = firstVertex + Int(mesh.triangleIndices[triangleStart + 1])
            let c = firstVertex + Int(mesh.triangleIndices[triangleStart + 2])
            obj += "f \(a) \(b) \(c)\n"
        }

        obj += "\n"
    }
}

struct VolumeExportResult: Hashable {
    var folderURL: URL
    var objURL: URL
    var mtlURL: URL
    var metadataURL: URL
    var textureCount: Int
    var actualSliceCount: Int
    var maskCount: Int
}

enum VolumeExportError: LocalizedError {
    case textureEncodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .textureEncodingFailed(let name):
            "Could not encode texture \(name)"
        }
    }
}
