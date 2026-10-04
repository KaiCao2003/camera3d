import Foundation

struct KeyenceGCIReader {
    func readMetadata(groupName: String, archiveURL: URL?) -> MicroscopeMetadata {
        var metadata = MicroscopeMetadata(groupName: groupName, archiveURL: archiveURL)

        guard let archiveURL else {
            return metadata
        }

        let stores = readStores(archiveURL: archiveURL, entries: Self.metadataEntries)

        if let image = stores[Self.imageEntry] {
            metadata.shootingDate = image["ShootingDateTime"].flatMap(Self.dateFromDotNetTicks)
            metadata.digitalZoom = image["DigitalZoom"].flatMap(Int.init)
            metadata.powerZoom = image["PowerZoom"].flatMap(Int.init)
            metadata.isOverlay = image["IsOverlay"].map { $0 == "True" } ?? false
            metadata.calibrationMicronsPerPixel = image["Calibration"].flatMap(Self.calibrationMicronsPerPixel)
        }

        if let size = stores[Self.originalSizeEntry] {
            metadata.originalImageSize = Self.pixelSize(from: size)
        }

        if let size = stores[Self.savingSizeEntry] {
            metadata.savingImageSize = Self.pixelSize(from: size)
        }

        if let lens = stores[Self.lensEntry] {
            metadata.lensName = lens["LensName"] ?? metadata.lensName
            metadata.lensType = lens["TypeName"] ?? ""
            metadata.magnificationPercent = lens["Magnification"].flatMap(Int.init)
            metadata.numericalAperture = lens["NumericalAperture"].flatMap(Self.keyenceDouble)
            metadata.workingDistanceMillimeters = lens["WorkingDistance"].flatMap(Self.keyenceDouble)
        }

        metadata.channels = (0..<8).compactMap { index in
            readChannel(index: index, stores: stores)
        }

        return metadata
    }

    private func readChannel(index: Int, stores: [String: [String: String]]) -> ChannelMetadata? {
        guard let base = stores[Self.channelEntry(index: index)] else {
            return nil
        }

        let parameters = stores[Self.channelParameterEntry(index: index)] ?? [:]
        let exposure = stores[Self.channelExposureEntry(index: index)] ?? [:]

        let numerator = exposure["Numerator"].flatMap(Double.init)
        let denominator = exposure["Denominator"].flatMap(Double.init)
        let exposureSeconds = if let numerator, let denominator, denominator != 0 {
            numerator / denominator
        } else {
            Optional<Double>.none
        }

        return ChannelMetadata(
            index: index,
            name: base["Comment"].flatMap { $0.isEmpty ? nil : $0 } ?? "Channel \(index)",
            isShot: base["IsShot"] == "True",
            isOverlay: base["IsOverlay"] == "True",
            pseudoColor: parameters["PseudoColor"],
            pixelMode: parameters["PixelMode"],
            cameraGain: parameters["CameraGain"].flatMap(Int.init),
            cameraGainUnit: parameters["CameraGainUnit"],
            exposureSeconds: exposureSeconds
        )
    }

    private func readStores(archiveURL: URL, entries: [String]) -> [String: [String: String]] {
        let requestedEntries = Set(entries)
        let existingEntries = availableEntries(in: archiveURL).filter { requestedEntries.contains($0) }
        guard !existingEntries.isEmpty else {
            return [:]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", archiveURL.path] + existingEntries

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return [:]
        }

        guard process.terminationStatus == 0 else {
            return [:]
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else {
            return [:]
        }

        return splitStores(data: data, entries: existingEntries)
    }

    private func availableEntries(in archiveURL: URL) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", archiveURL.path]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        guard process.terminationStatus == 0 else {
            return []
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return []
        }

        return output.split(whereSeparator: \.isNewline).map(String.init)
    }

    private func splitStores(data: Data, entries: [String]) -> [String: [String: String]] {
        guard let output = String(data: data, encoding: .utf8) else {
            return [:]
        }

        var stores: [String: [String: String]] = [:]
        var cursor = output.startIndex

        for entry in entries {
            guard let endRange = output[cursor...].range(of: "</Store>") else {
                break
            }
            let end = endRange.upperBound
            let document = String(output[cursor..<end])
            if let documentData = document.data(using: .utf8),
               let values = StoreXMLReader.parse(data: documentData) {
                stores[entry] = values
            }
            cursor = end
        }

        return stores
    }

    private static func pixelSize(from values: [String: String]) -> PixelSize? {
        guard let width = values["Width"].flatMap(Int.init),
              let height = values["Height"].flatMap(Int.init) else {
            return nil
        }
        return PixelSize(width: width, height: height)
    }

    private static func dateFromDotNetTicks(_ raw: String) -> Date? {
        guard let ticks = Int64(raw) else {
            return nil
        }
        let unixEpochTicks: Int64 = 621_355_968_000_000_000
        let seconds = Double(ticks - unixEpochTicks) / 10_000_000.0
        return Date(timeIntervalSince1970: seconds)
    }

    private static func keyenceDouble(_ raw: String) -> Double? {
        if let direct = Double(raw), abs(direct) < 1_000_000 {
            return direct
        }
        guard let bits = UInt64(raw) else {
            return Double(raw)
        }
        return Double(bitPattern: bits)
    }

    /// Keyence stores this field in nanometres per pixel for the microscope
    /// files used by BrainBuilder. Older app builds decoded the IEEE-754 value
    /// correctly but then labelled it as micrometres, inflating every physical
    /// coordinate by 1,000x.
    static func calibrationMicronsPerPixel(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let microns: Double
        if trimmed.count >= 15, let bits = UInt64(trimmed) {
            let nanometres = Double(bitPattern: bits)
            guard nanometres.isFinite, nanometres > 0 else {
                return nil
            }
            microns = nanometres / 1_000.0
        } else if let directMicrons = Double(trimmed), directMicrons.isFinite, directMicrons > 0 {
            microns = directMicrons
        } else {
            return nil
        }
        guard (0.1...100).contains(microns) else {
            return nil
        }
        return microns
    }

    private static let imageEntry = "GroupFileProperty/Image/properties.xml"
    private static let originalSizeEntry = "GroupFileProperty/Image/OriginalImageSize/properties.xml"
    private static let savingSizeEntry = "GroupFileProperty/Image/SavingImageSize/properties.xml"
    private static let lensEntry = "GroupFileProperty/Lens/properties.xml"

    private static var metadataEntries: [String] {
        var entries = [
            imageEntry,
            originalSizeEntry,
            savingSizeEntry,
            lensEntry
        ]
        for index in 0..<8 {
            entries.append(channelEntry(index: index))
            entries.append(channelParameterEntry(index: index))
            entries.append(channelExposureEntry(index: index))
        }
        return entries
    }

    private static func channelEntry(index: Int) -> String {
        "GroupFileProperty/Channel\(index)/properties.xml"
    }

    private static func channelParameterEntry(index: Int) -> String {
        "GroupFileProperty/Channel\(index)/Shooting/Parameter/properties.xml"
    }

    private static func channelExposureEntry(index: Int) -> String {
        "GroupFileProperty/Channel\(index)/Shooting/Parameter/ExposureTime/properties.xml"
    }
}

private final class StoreXMLReader: NSObject, XMLParserDelegate {
    private var values: [String: String] = [:]
    private var currentElement: String?
    private var buffer = ""

    static func parse(data: Data) -> [String: String]? {
        let delegate = StoreXMLReader()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            return nil
        }
        return delegate.values
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName != "Store" else {
            return
        }
        currentElement = elementName
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard currentElement == elementName else {
            return
        }
        values[elementName] = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        currentElement = nil
        buffer = ""
    }
}
