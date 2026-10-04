import Foundation

enum DatasetScanError: LocalizedError {
    case noXYGroups(String)
    case noMicroscopeImages(String)

    var errorDescription: String? {
        switch self {
        case .noXYGroups(let path):
            "No XY group folders were found in \(path). Choose the folder that directly contains XY01, XY02, and related groups."
        case .noMicroscopeImages(let path):
            "No supported montage or numbered TIFF images were found in \(path)."
        }
    }
}

struct DatasetScanner {
    func scan(rootURL: URL) throws -> BrainDataset {
        let fileManager = FileManager.default
        let groupFolders = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && url.lastPathComponent.uppercased().hasPrefix("XY")
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !groupFolders.isEmpty else {
            throw DatasetScanError.noXYGroups(rootURL.path)
        }

        let reader = KeyenceGCIReader()
        var groups: [BrainGroup] = []
        groups.reserveCapacity(groupFolders.count)

        for folderURL in groupFolders {
            try Task.checkCancellation()
            groups.append(try scanGroup(folderURL: folderURL, reader: reader))
        }

        guard groups.contains(where: { $0.montageOverlayURL != nil || !$0.slices.isEmpty }) else {
            throw DatasetScanError.noMicroscopeImages(rootURL.path)
        }

        return BrainDataset(rootURL: rootURL, groups: groups)
    }

    private func scanGroup(folderURL: URL, reader: KeyenceGCIReader) throws -> BrainGroup {
        let fileManager = FileManager.default
        let groupID = folderURL.lastPathComponent
        let files = try fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        let gciURL = files.first { $0.pathExtension.lowercased() == "gci" }
        let metadata = reader.readMetadata(groupName: groupID, archiveURL: gciURL)
        let tiffs = files.filter { ["tif", "tiff"].contains($0.pathExtension.lowercased()) }

        var sliceBuckets: [Int: BrainSliceBucket] = [:]
        var montageOverlayURL: URL?
        var montageChannel2URL: URL?
        var montageChannel3URL: URL?

        for url in tiffs {
            try Task.checkCancellation()
            let name = url.deletingPathExtension().lastPathComponent

            if name.localizedCaseInsensitiveContains("Untitled") {
                if name.hasSuffix("_Overlay") {
                    montageOverlayURL = url
                } else if name.hasSuffix("_CH2") {
                    montageChannel2URL = url
                } else if name.hasSuffix("_CH3") {
                    montageChannel3URL = url
                }
                continue
            }

            guard let index = Self.numberedImageIndex(from: name) else {
                continue
            }

            var bucket = sliceBuckets[index, default: BrainSliceBucket(index: index)]
            if name.hasSuffix("_Overlay") {
                bucket.overlayURL = url
            } else if name.hasSuffix("_CH2") {
                bucket.channel2URL = url
            } else if name.hasSuffix("_CH3") {
                bucket.channel3URL = url
            }
            sliceBuckets[index] = bucket
        }

        let slices = sliceBuckets.values
            .sorted { $0.index < $1.index }
            .map { bucket in
                BrainSlice(
                    id: "\(groupID)-\(bucket.index)",
                    groupID: groupID,
                    index: bucket.index,
                    overlayURL: bucket.overlayURL,
                    channel2URL: bucket.channel2URL,
                    channel3URL: bucket.channel3URL,
                    isMontage: false
                )
            }

        return BrainGroup(
            id: groupID,
            folderURL: folderURL,
            metadata: metadata,
            slices: slices,
            montageOverlayURL: montageOverlayURL,
            montageChannel2URL: montageChannel2URL,
            montageChannel3URL: montageChannel3URL
        )
    }

    private static func numberedImageIndex(from stem: String) -> Int? {
        let range = NSRange(stem.startIndex..<stem.endIndex, in: stem)
        guard let match = numberedImageRegex.firstMatch(in: stem, range: range),
              match.numberOfRanges > 1,
              let indexRange = Range(match.range(at: 1), in: stem) else {
            return nil
        }
        return Int(stem[indexRange])
    }

    private static let numberedImageRegex = try! NSRegularExpression(pattern: #"_(\d{5})_"#)
}

private struct BrainSliceBucket {
    var index: Int
    var overlayURL: URL?
    var channel2URL: URL?
    var channel3URL: URL?
}
