import AppKit
import CoreGraphics
import Foundation
import ImageIO

struct BrainVolumeBuilder {
    var maxTexturePixels = 1400
    var sliceSpacing = 0.12

    func build(dataset: BrainDataset, mode: StackSourceMode) throws -> BrainVolume {
        switch mode {
        case .montageSections:
            try buildFromMontages(dataset: dataset)
        case .numberedOverlays:
            try buildFromNumberedOverlays(dataset: dataset)
        }
    }

    private func buildFromMontages(dataset: BrainDataset) throws -> BrainVolume {
        var volumeSlices: [VolumeSlice] = []
        var rejected = 0
        var sourceImages = 0

        for group in dataset.groups {
            try Task.checkCancellation()
            guard let montageURL = group.montageOverlayURL,
                  let thumbnail = ImageProcessingService.loadThumbnail(url: montageURL, maxPixelSize: maxTexturePixels) else {
                continue
            }
            sourceImages += 1

            let channelThumbnails = ImageProcessingService.channelThumbnails(
                metadata: group.metadata,
                channelURLs: [group.montageChannel2URL, group.montageChannel3URL],
                maxPixelSize: maxTexturePixels
            )
            let sourcePixelScale = ImageProcessingService.sourcePixelScale(url: montageURL, thumbnail: thumbnail)

            let components = ImageProcessingService.detectTissueComponents(in: thumbnail)
            rejected += components.rejected
            let ownership = ImageProcessingService.registrationSelectionOwnership(
                components: components.accepted,
                imageSize: PixelSize(width: thumbnail.width, height: thumbnail.height)
            )

            for (componentIndex, component) in components.accepted.enumerated() {
                let cropRect = component.expandedCrop(in: thumbnail)
                guard let cropped = thumbnail.cropping(to: cropRect),
                      let processed = ImageProcessingService.makeTransparentTexture(
                        from: cropped,
                        sourceComponent: component.normalized(toCrop: cropRect)
                      ) else {
                    continue
                }

                let channelImages = channelThumbnails.compactMap { channel -> VolumeChannelImage? in
                    let scaleX = CGFloat(channel.image.width) / CGFloat(max(1, thumbnail.width))
                    let scaleY = CGFloat(channel.image.height) / CGFloat(max(1, thumbnail.height))
                    let channelCropRect = CGRect(
                        x: cropRect.origin.x * scaleX,
                        y: cropRect.origin.y * scaleY,
                        width: cropRect.width * scaleX,
                        height: cropRect.height * scaleY
                    ).integral
                    guard let crop = channel.image.cropping(to: channelCropRect) else {
                        return nil
                    }
                    let montageCropRect = CGRect(
                        x: channelCropRect.minX / scaleX,
                        y: channelCropRect.minY / scaleY,
                        width: CGFloat(crop.width) / scaleX,
                        height: CGFloat(crop.height) / scaleY
                    )
                    let outputSize = PixelSize(width: crop.width, height: crop.height)
                    return VolumeChannelImage(
                        channelIndex: channel.channelIndex,
                        name: channel.name,
                        pseudoColor: channel.pseudoColor,
                        sourceURL: channel.sourceURL,
                        texture: NSImage(cgImage: crop, size: NSSize(width: crop.width, height: crop.height)),
                        sourcePixelScale: channel.sourcePixelScale,
                        registrationSelectionMask: ownership.mask(
                            for: componentIndex, cropRect: montageCropRect, outputImageSize: outputSize
                        ),
                        registrationSeedMask: ownership.mask(
                            for: componentIndex, cropRect: montageCropRect, outputImageSize: outputSize,
                            seedsOnly: true
                        )
                    )
                }

                let volumeIndex = volumeSlices.count
                let calibration = group.metadata.calibrationMicronsPerPixel
                volumeSlices.append(
                    VolumeSlice(
                        id: "\(group.id)-montage-\(componentIndex)",
                        title: "\(group.id) section \(componentIndex + 1)",
                        sourceURL: montageURL,
                        groupID: group.id,
                        texture: processed.image,
                        width: processed.aspectWidth,
                        height: processed.aspectHeight,
                        z: Double(volumeIndex) * sliceSpacing,
                        offsetX: processed.centerOffsetX,
                        offsetY: processed.centerOffsetY,
                        opacity: 0.62,
                        signal: processed.signal,
                        registration: .unregistered,
                        cortex: .unregistered,
                        channelImages: channelImages,
                        sourcePixelScale: sourcePixelScale,
                        nativeCropRect: CGRect(
                            x: cropRect.origin.x * sourcePixelScale,
                            y: cropRect.origin.y * sourcePixelScale,
                            width: cropRect.width * sourcePixelScale,
                            height: cropRect.height * sourcePixelScale
                        ),
                        physicalWidthMicrons: calibration.map {
                            Double(cropRect.width) * sourcePixelScale * $0
                        },
                        physicalHeightMicrons: calibration.map {
                            Double(cropRect.height) * sourcePixelScale * $0
                        }
                    )
                )
            }
        }

        let atlasRegistered = AtlasRegistrationService().register(volumeSlices, mode: .montageSections)
        let cortexRegistered = CortexRegistrationService().register(atlasRegistered.slices, mode: .montageSections)
        let buildSummary = VolumeBuildSummary(
            sourceImages: sourceImages,
            producedSlices: cortexRegistered.slices.count,
            rejectedComponents: rejected,
            maxTexturePixels: maxTexturePixels,
            meanForegroundConfidence: meanForegroundConfidence(cortexRegistered.slices),
            meanBackgroundRemoved: meanBackgroundRemoved(cortexRegistered.slices)
        )
        let reliabilityReport = RegistrationReliabilityService().verify(
            dataset: dataset,
            slices: cortexRegistered.slices,
            atlasRegistration: atlasRegistered.summary,
            cortexRegistration: cortexRegistered.summary,
            buildSummary: buildSummary,
            mode: .montageSections
        )

        return BrainVolume(
            sourceMode: .montageSections,
            slices: cortexRegistered.slices,
            bounds: bounds(for: cortexRegistered.slices),
            atlasRegistration: atlasRegistered.summary,
            cortexRegistration: cortexRegistered.summary,
            buildSummary: buildSummary,
            reliabilityReport: reliabilityReport
        )
    }

    private func buildFromNumberedOverlays(dataset: BrainDataset) throws -> BrainVolume {
        var volumeSlices: [VolumeSlice] = []
        let numberedSlices = dataset.allNumberedOverlaySlices

        for slice in numberedSlices {
            try Task.checkCancellation()
            guard let overlayURL = slice.overlayURL,
                  let thumbnail = ImageProcessingService.loadThumbnail(url: overlayURL, maxPixelSize: maxTexturePixels),
                  let processed = ImageProcessingService.makeTransparentTexture(from: thumbnail) else {
                continue
            }

            let volumeIndex = volumeSlices.count
            let metadata = dataset.groups.first { $0.id == slice.groupID }?.metadata
                ?? MicroscopeMetadata(groupName: slice.groupID, archiveURL: nil)
            let channelImages = ImageProcessingService.channelThumbnails(
                metadata: metadata,
                channelURLs: [slice.channel2URL, slice.channel3URL],
                maxPixelSize: maxTexturePixels
            ).map { channel in
                VolumeChannelImage(
                    channelIndex: channel.channelIndex,
                    name: channel.name,
                    pseudoColor: channel.pseudoColor,
                    sourceURL: channel.sourceURL,
                    texture: NSImage(
                        cgImage: channel.image,
                        size: NSSize(width: channel.image.width, height: channel.image.height)
                    ),
                    sourcePixelScale: channel.sourcePixelScale
                )
            }
            let sourcePixelScale = ImageProcessingService.sourcePixelScale(url: overlayURL, thumbnail: thumbnail)
            let calibration = metadata.calibrationMicronsPerPixel
            volumeSlices.append(
                VolumeSlice(
                    id: slice.id,
                    title: "\(slice.groupID) \(String(format: "%05d", slice.index))",
                    sourceURL: overlayURL,
                    groupID: slice.groupID,
                    texture: processed.image,
                    width: processed.aspectWidth,
                    height: processed.aspectHeight,
                    z: Double(volumeIndex) * sliceSpacing,
                    offsetX: processed.centerOffsetX,
                    offsetY: processed.centerOffsetY,
                    opacity: 0.48,
                    signal: processed.signal,
                    registration: .unregistered,
                    cortex: .unregistered,
                    channelImages: channelImages,
                    sourcePixelScale: sourcePixelScale,
                    nativeCropRect: CGRect(
                        x: 0,
                        y: 0,
                        width: CGFloat(thumbnail.width) * sourcePixelScale,
                        height: CGFloat(thumbnail.height) * sourcePixelScale
                    ),
                    physicalWidthMicrons: calibration.map {
                        Double(thumbnail.width) * sourcePixelScale * $0
                    },
                    physicalHeightMicrons: calibration.map {
                        Double(thumbnail.height) * sourcePixelScale * $0
                    }
                )
            )
        }

        let atlasRegistered = AtlasRegistrationService().register(volumeSlices, mode: .numberedOverlays)
        let cortexRegistered = CortexRegistrationService().register(atlasRegistered.slices, mode: .numberedOverlays)
        let buildSummary = VolumeBuildSummary(
            sourceImages: numberedSlices.count,
            producedSlices: cortexRegistered.slices.count,
            rejectedComponents: 0,
            maxTexturePixels: maxTexturePixels,
            meanForegroundConfidence: meanForegroundConfidence(cortexRegistered.slices),
            meanBackgroundRemoved: meanBackgroundRemoved(cortexRegistered.slices)
        )
        let reliabilityReport = RegistrationReliabilityService().verify(
            dataset: dataset,
            slices: cortexRegistered.slices,
            atlasRegistration: atlasRegistered.summary,
            cortexRegistration: cortexRegistered.summary,
            buildSummary: buildSummary,
            mode: .numberedOverlays
        )

        return BrainVolume(
            sourceMode: .numberedOverlays,
            slices: cortexRegistered.slices,
            bounds: bounds(for: cortexRegistered.slices),
            atlasRegistration: atlasRegistered.summary,
            cortexRegistration: cortexRegistered.summary,
            buildSummary: buildSummary,
            reliabilityReport: reliabilityReport
        )
    }

    private func bounds(for slices: [VolumeSlice]) -> SIMD3<Double> {
        guard !slices.isEmpty else {
            return SIMD3<Double>(0, 0, 0)
        }
        let width = slices.map(\.width).max() ?? 0
        let height = slices.map(\.height).max() ?? 0
        let depth = (slices.map(\.z).max() ?? 0) - (slices.map(\.z).min() ?? 0)
        return SIMD3<Double>(width, height, depth)
    }

    private func meanForegroundConfidence(_ slices: [VolumeSlice]) -> Double {
        guard !slices.isEmpty else {
            return 0
        }
        return slices.map(\.signal.foregroundConfidence).reduce(0, +) / Double(slices.count)
    }

    private func meanBackgroundRemoved(_ slices: [VolumeSlice]) -> Double {
        guard !slices.isEmpty else {
            return 0
        }
        return slices.map(\.signal.backgroundSuppression).reduce(0, +) / Double(slices.count)
    }
}

enum ImageProcessingService {
    struct ChannelThumbnail {
        var channelIndex: Int
        var name: String
        var pseudoColor: String?
        var sourceURL: URL
        var image: CGImage
        var sourcePixelScale: Double
    }

    static func loadThumbnail(url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func channelThumbnails(
        metadata: MicroscopeMetadata,
        channelURLs: [URL?],
        maxPixelSize: Int
    ) -> [ChannelThumbnail] {
        let channels = metadata.capturedChannels.sorted { $0.index < $1.index }
        return zip(channels, channelURLs).compactMap { channel, optionalURL in
            guard let url = optionalURL,
                  let image = loadThumbnail(url: url, maxPixelSize: maxPixelSize) else {
                return nil
            }
            return ChannelThumbnail(
                channelIndex: channel.index,
                name: channel.name,
                pseudoColor: channel.pseudoColor,
                sourceURL: url,
                image: image,
                sourcePixelScale: sourcePixelScale(url: url, thumbnail: image)
            )
        }
    }

    static func sourcePixelScale(url: URL, thumbnail: CGImage) -> Double {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return 1
        }
        let widthScale = width.doubleValue / Double(max(1, thumbnail.width))
        let heightScale = height.doubleValue / Double(max(1, thumbnail.height))
        return max(1, max(widthScale, heightScale))
    }

    static func rotated180(_ image: NSImage) -> NSImage? {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let source = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }
        let width = source.width
        let height = source.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.translateBy(x: CGFloat(width), y: CGFloat(height))
        context.rotate(by: .pi)
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let rotated = context.makeImage() else {
            return nil
        }
        return NSImage(cgImage: rotated, size: NSSize(width: width, height: height))
    }

    /// Assign each montage pixel at most once by eight-neighbor grid distance
    /// from accepted component support. This is a selection domain, not a
    /// tissue segmentation; dim pixels remain available to registration.
    static func registrationSelectionOwnership(
        components: [TissueComponent],
        imageSize: PixelSize
    ) -> RegistrationSelectionOwnership {
        let width = imageSize.width
        let height = imageSize.height
        var owners = [Int32](repeating: -1, count: width * height)
        var queue: [Int] = []
        queue.reserveCapacity(width * height)
        let imageBounds = CGRect(x: 0, y: 0, width: width, height: height)
        let domains = components.map { component in
            let padding = max(2, min(component.bounds.width, component.bounds.height) * 0.01)
            return component.bounds.insetBy(dx: -padding, dy: -padding).intersection(imageBounds)
        }
        // Seed every component before expansion so no neighbor can claim its
        // observed support. Component order and FIFO traversal resolve ties.
        for (index, component) in components.enumerated() {
            for pixel in component.seedPixelIndices {
                owners[pixel] = Int32(index)
                queue.append(pixel)
            }
        }
        let seedOwners = owners
        var head = 0
        while head < queue.count {
            let pixel = queue[head]
            head += 1
            let owner = owners[pixel]
            let domain = domains[Int(owner)]
            let x = pixel % width
            let y = pixel / width
            for nextY in max(0, y - 1)...min(height - 1, y + 1) {
                for nextX in max(0, x - 1)...min(width - 1, x + 1) {
                    let next = nextY * width + nextX
                    guard owners[next] == -1,
                          domain.contains(CGPoint(x: CGFloat(nextX) + 0.5, y: CGFloat(nextY) + 0.5)) else {
                        continue
                    }
                    owners[next] = owner
                    queue.append(next)
                }
            }
        }
        return RegistrationSelectionOwnership(imageSize: imageSize, owners: owners, seedOwners: seedOwners)
    }

    static func bilateralAlphaSymmetry(_ image: NSImage, alphaThreshold: UInt8 = 20) -> Double {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil),
              let pixels = rgbaPixels(from: cgImage) else {
            return 0
        }
        let width = cgImage.width
        let height = cgImage.height
        var minX = width
        var maxX = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > alphaThreshold {
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
        }
        guard maxX >= minX else { return 0 }
        let axis = Double(minX + maxX) / 2
        let radius = Int(floor(Double(maxX - minX + 1) / 2))
        var intersection = 0
        var union = 0
        for y in 0..<height {
            for distance in 0...radius {
                let leftX = Int(floor(axis - Double(distance)))
                let rightX = Int(ceil(axis + Double(distance)))
                guard leftX >= 0, rightX < width else { continue }
                let left = pixels[(y * width + leftX) * 4 + 3] > alphaThreshold
                let right = pixels[(y * width + rightX) * 4 + 3] > alphaThreshold
                if left || right { union += 1 }
                if left && right { intersection += 1 }
            }
        }
        return union > 0 ? Double(intersection) / Double(union) : 0
    }

    static func makeTransparentTexture(from image: CGImage, sourceComponent: TissueComponent? = nil) -> ProcessedTexture? {
        guard var pixels = rgbaPixels(from: image) else {
            return nil
        }

        let width = image.width
        let height = image.height
        var redSum = 0.0
        var greenSum = 0.0
        var blueSum = 0.0
        var alphaPixels = 0
        var minX = width
        var minY = height
        var maxX = 0
        var maxY = 0
        let componentDomain = sourceComponent.map { component -> CGRect in
            let padding = max(2, min(component.bounds.width, component.bounds.height) * 0.01)
            return component.bounds
                .insetBy(dx: -padding, dy: -padding)
                .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        }

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let red = Int(pixels[offset])
                let green = Int(pixels[offset + 1])
                let blue = Int(pixels[offset + 2])
                let brightness = max(red, green, blue)
                let broadSignal = brightness > 20 || red + green > 55 || green > 30
                let warmTissue = red > 48 && green > 32 && red + green > 118 && red > blue + 16
                let greenSignal = green > 70 && green > red + 8 && green > blue + 20
                // Montage crops include a narrow halo of fluorescent background.
                // Use the same evidence that produced the tissue component so the
                // 3D preview does not render each crop as a translucent rectangle.
                let insideSelectedComponent = componentDomain?.contains(
                    CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                ) ?? true
                let tissue = sourceComponent == nil
                    ? broadSignal
                    : (insideSelectedComponent && (warmTissue || greenSignal))

                if tissue {
                    let baseline = sourceComponent == nil ? 10 : 24
                    let alpha = min(235, max(28, (brightness - baseline) * 3))
                    pixels[offset + 3] = UInt8(alpha)
                    redSum += Double(red)
                    greenSum += Double(green)
                    blueSum += Double(blue)
                    alphaPixels += 1
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                } else {
                    pixels[offset + 3] = 0
                }
            }
        }

        guard let processed = cgImage(width: width, height: height, pixels: pixels) else {
            return nil
        }

        let nsImage = NSImage(cgImage: processed, size: NSSize(width: width, height: height))
        let aspectWidth: Double
        let aspectHeight: Double
        if width >= height {
            aspectWidth = 1.0
            aspectHeight = Double(height) / Double(width)
        } else {
            aspectHeight = 1.0
            aspectWidth = Double(width) / Double(height)
        }

        let coverage = Double(alphaPixels) / Double(max(1, width * height))
        let componentCoverage = sourceComponent.map {
            Double($0.area) / Double(max(1, width * height))
        } ?? coverage
        let bounds: CGRect
        let centerOffsetX: Double
        let centerOffsetY: Double

        if alphaPixels > 0 {
            bounds = CGRect(
                x: minX,
                y: minY,
                width: max(1, maxX - minX + 1),
                height: max(1, maxY - minY + 1)
            )
            let centerX = Double(minX + maxX) / 2.0
            let centerY = Double(minY + maxY) / 2.0
            centerOffsetX = (0.5 - centerX / Double(width)) * aspectWidth
            centerOffsetY = (centerY / Double(height) - 0.5) * aspectHeight
        } else {
            bounds = .zero
            centerOffsetX = 0
            centerOffsetY = 0
        }

        return ProcessedTexture(
            image: nsImage,
            aspectWidth: aspectWidth,
            aspectHeight: aspectHeight,
            centerOffsetX: centerOffsetX,
            centerOffsetY: centerOffsetY,
            signal: SliceSignal(
                redMean: redSum / Double(max(1, alphaPixels)),
                greenMean: greenSum / Double(max(1, alphaPixels)),
                blueMean: blueSum / Double(max(1, alphaPixels)),
                alphaCoverage: coverage,
                tissueBounds: bounds,
                imageSize: PixelSize(width: width, height: height),
                componentAreaPixels: sourceComponent?.area ?? alphaPixels,
                componentBounds: sourceComponent?.bounds ?? bounds,
                foregroundConfidence: foregroundConfidence(
                    coverage: coverage,
                    bounds: bounds,
                    imageSize: PixelSize(width: width, height: height),
                    component: sourceComponent
                ),
                backgroundSuppression: (1.0 - componentCoverage).clamped(to: 0...1)
            )
        )
    }

    private static func foregroundConfidence(
        coverage: Double,
        bounds: CGRect,
        imageSize: PixelSize,
        component: TissueComponent?
    ) -> Double {
        let boundsArea = max(1.0, bounds.width * bounds.height)
        let imageArea = max(1.0, Double(imageSize.width * imageSize.height))
        let compactness = min(1, boundsArea / imageArea * 1.8)
        let coverageScore = min(1, coverage / 0.55)
        let componentScore = component.map { min(1, Double($0.area) / boundsArea) } ?? coverageScore
        return (coverageScore * 0.45 + compactness * 0.25 + componentScore * 0.30).clamped(to: 0...1)
    }

    static func detectTissueComponents(in image: CGImage) -> TissueComponentResult {
        guard let pixels = rgbaPixels(from: image) else {
            return TissueComponentResult(accepted: [], rejected: 0)
        }

        let width = image.width
        let height = image.height
        let pixelCount = width * height
        let minimumArea = max(1_500, pixelCount / 180)
        var visited = [Bool](repeating: false, count: pixelCount)
        var candidates: [TissueComponent] = []
        var rejected = 0

        func isTissue(_ index: Int) -> Bool {
            let offset = index * 4
            let red = Int(pixels[offset])
            let green = Int(pixels[offset + 1])
            let blue = Int(pixels[offset + 2])
            let warmTissue = red > 48 && green > 32 && red + green > 118 && red > blue + 16
            let greenSignal = green > 70 && green > red + 8 && green > blue + 20
            return warmTissue || greenSignal
        }

        for start in 0..<pixelCount {
            if visited[start] || !isTissue(start) {
                continue
            }

            var queue = [start]
            visited[start] = true
            var head = 0
            var area = 0
            var minX = width
            var minY = height
            var maxX = 0
            var maxY = 0
            var memberPixels: [Int] = []

            while head < queue.count {
                let current = queue[head]
                head += 1
                area += 1
                memberPixels.append(current)

                let x = current % width
                let y = current / width
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)

                if x > 0 {
                    let neighbor = current - 1
                    if !visited[neighbor] && isTissue(neighbor) {
                        visited[neighbor] = true
                        queue.append(neighbor)
                    }
                }
                if x + 1 < width {
                    let neighbor = current + 1
                    if !visited[neighbor] && isTissue(neighbor) {
                        visited[neighbor] = true
                        queue.append(neighbor)
                    }
                }
                if y > 0 {
                    let neighbor = current - width
                    if !visited[neighbor] && isTissue(neighbor) {
                        visited[neighbor] = true
                        queue.append(neighbor)
                    }
                }
                if y + 1 < height {
                    let neighbor = current + width
                    if !visited[neighbor] && isTissue(neighbor) {
                        visited[neighbor] = true
                        queue.append(neighbor)
                    }
                }
            }

            let rect = CGRect(
                x: minX,
                y: minY,
                width: max(1, maxX - minX + 1),
                height: max(1, maxY - minY + 1)
            )
            let component = TissueComponent(bounds: rect, area: area, seedPixelIndices: memberPixels)

            let imageSize = PixelSize(width: width, height: height)
            if area >= minimumArea,
               component.isPlausibleCoronalSection(in: imageSize) {
                candidates.append(component)
            } else if let split = splitWideComponent(
                pixelIndices: memberPixels,
                bounds: rect,
                imageSize: imageSize,
                minimumArea: minimumArea
            ) {
                candidates.append(contentsOf: split)
            } else {
                rejected += 1
            }
        }

        var accepted = removeSmallSectionOutliers(candidates)
        rejected += candidates.count - accepted.count

        accepted.sort { lhs, rhs in
            let rowTolerance = Double(height) * 0.12
            if abs(lhs.bounds.midY - rhs.bounds.midY) > rowTolerance {
                return lhs.bounds.midY < rhs.bounds.midY
            }
            return lhs.bounds.midX < rhs.bounds.midX
        }

        return TissueComponentResult(accepted: accepted, rejected: rejected)
    }

    /// A narrow fluorescent bridge can join two otherwise valid neighboring
    /// sections. Split only very wide components, at the least occupied column
    /// near their center, and accept the split only when both halves independently
    /// satisfy the section geometry checks. This keeps the fallback conservative.
    static func splitWideComponent(
        pixelIndices: [Int],
        bounds: CGRect,
        imageSize: PixelSize,
        minimumArea: Int
    ) -> [TissueComponent]? {
        guard !pixelIndices.isEmpty,
              bounds.width / max(1, bounds.height) > 2.45,
              pixelIndices.count >= minimumArea * 2 else {
            return nil
        }

        let imageWidth = max(1, imageSize.width)
        let minX = max(0, Int(bounds.minX.rounded(.down)))
        let maxX = min(imageWidth - 1, Int(bounds.maxX.rounded(.up)) - 1)
        let span = maxX - minX + 1
        guard span >= 8 else {
            return nil
        }

        var projection = [Int](repeating: 0, count: span)
        for index in pixelIndices {
            let x = index % imageWidth
            if x >= minX && x <= maxX {
                projection[x - minX] += 1
            }
        }

        let searchStart = max(2, Int(Double(span) * 0.35))
        let searchEnd = min(span - 3, Int(Double(span) * 0.65))
        guard searchStart <= searchEnd else {
            return nil
        }

        var bestOffset = searchStart
        var bestScore = Int.max
        for offset in searchStart...searchEnd {
            let score = projection[(offset - 2)...(offset + 2)].reduce(0, +)
            if score < bestScore {
                bestScore = score
                bestOffset = offset
            }
        }
        let splitX = minX + bestOffset

        let leftPixels = pixelIndices.filter { $0 % imageWidth < splitX }
        let rightPixels = pixelIndices.filter { $0 % imageWidth >= splitX }
        guard let left = component(from: leftPixels, imageWidth: imageWidth),
              let right = component(from: rightPixels, imageWidth: imageWidth),
              left.area >= minimumArea,
              right.area >= minimumArea,
              left.isPlausibleCoronalSection(in: imageSize),
              right.isPlausibleCoronalSection(in: imageSize) else {
            return nil
        }
        return [left, right]
    }

    private static func component(from pixelIndices: [Int], imageWidth: Int) -> TissueComponent? {
        guard let first = pixelIndices.first else {
            return nil
        }
        var minX = first % imageWidth
        var maxX = minX
        var minY = first / imageWidth
        var maxY = minY
        for index in pixelIndices.dropFirst() {
            let x = index % imageWidth
            let y = index / imageWidth
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }
        return TissueComponent(
            bounds: CGRect(
                x: minX,
                y: minY,
                width: max(1, maxX - minX + 1),
                height: max(1, maxY - minY + 1)
            ),
            area: pixelIndices.count,
            seedPixelIndices: pixelIndices
        )
    }

    static func removeSmallSectionOutliers(_ components: [TissueComponent]) -> [TissueComponent] {
        guard let largestArea = components.map(\.area).max(), largestArea > 0 else {
            return []
        }
        let minimumRelativeArea = Int(Double(largestArea) * 0.18)
        return components.filter { component in
            component.area >= minimumRelativeArea
        }
    }

    private static func rgbaPixels(
        from image: CGImage,
        width: Int? = nil,
        height: Int? = nil
    ) -> [UInt8]? {
        let width = width ?? image.width
        let height = height ?? image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    private static func cgImage(width: Int, height: Int, pixels: [UInt8]) -> CGImage? {
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else {
            return nil
        }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

struct RegistrationSelectionOwnership {
    var imageSize: PixelSize
    var owners: [Int32]
    var seedOwners: [Int32]

    func mask(
        for componentIndex: Int,
        cropRect: CGRect,
        outputImageSize: PixelSize,
        seedsOnly: Bool = false
    ) -> NSImage? {
        let width = outputImageSize.width
        let height = outputImageSize.height
        guard width > 0, height > 0 else { return nil }
        let values = seedsOnly ? seedOwners : owners
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let sourceY = Int(floor(cropRect.minY + (CGFloat(y) + 0.5) * cropRect.height / CGFloat(height)))
            for x in 0..<width {
                let sourceX = Int(floor(cropRect.minX + (CGFloat(x) + 0.5) * cropRect.width / CGFloat(width)))
                if sourceX >= 0, sourceX < imageSize.width, sourceY >= 0, sourceY < imageSize.height,
                   values[sourceY * imageSize.width + sourceX] == Int32(componentIndex) {
                    pixels[y * width + x] = 255
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: width, height: height))
    }
}

struct ProcessedTexture {
    var image: NSImage
    var aspectWidth: Double
    var aspectHeight: Double
    var centerOffsetX: Double
    var centerOffsetY: Double
    var signal: SliceSignal
}

struct TissueComponent {
    var bounds: CGRect
    var area: Int
    /// Absolute pixel indices in the original montage thumbnail.
    var seedPixelIndices: [Int] = []

    func isPlausibleCoronalSection(in imageSize: PixelSize) -> Bool {
        let imageWidth = CGFloat(max(1, imageSize.width))
        let imageHeight = CGFloat(max(1, imageSize.height))
        let minimumWidth = max(CGFloat(120), imageWidth * 0.13)
        let minimumHeight = max(CGFloat(80), imageHeight * 0.08)
        let aspectRatio = bounds.width / max(1, bounds.height)
        let fillRatio = CGFloat(area) / max(1, bounds.width * bounds.height)
        let touchesSideEdge = bounds.minX <= imageWidth * 0.01 || bounds.maxX >= imageWidth * 0.99
        let edgeStrip = touchesSideEdge && (aspectRatio < 0.75 || fillRatio < 0.28)

        return bounds.width >= minimumWidth
            && bounds.height >= minimumHeight
            && aspectRatio >= 1.0
            && aspectRatio <= 2.75
            && fillRatio >= 0.18
            && !edgeStrip
    }

    func expandedCrop(in image: CGImage) -> CGRect {
        let padding = max(bounds.width, bounds.height) * 0.04
        return bounds
            .insetBy(dx: -padding, dy: -padding)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            .integral
    }

    func normalized(toCrop crop: CGRect) -> TissueComponent {
        let translated = bounds.offsetBy(dx: -crop.minX, dy: -crop.minY)
        return TissueComponent(bounds: translated, area: area)
    }
}

struct TissueComponentResult {
    var accepted: [TissueComponent]
    var rejected: Int
}
