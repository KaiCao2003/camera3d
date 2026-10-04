import Foundation

struct MicroscopeMetadata: Identifiable, Hashable {
    var id: String { groupName }

    let groupName: String
    var archiveURL: URL?
    var lensName: String = "Unknown lens"
    var lensType: String = ""
    var magnificationPercent: Int?
    var numericalAperture: Double?
    var workingDistanceMillimeters: Double?
    var originalImageSize: PixelSize?
    var savingImageSize: PixelSize?
    var shootingDate: Date?
    var digitalZoom: Int?
    var powerZoom: Int?
    var isOverlay: Bool = false
    var calibrationMicronsPerPixel: Double?
    var channels: [ChannelMetadata] = []

    var capturedChannels: [ChannelMetadata] {
        channels.filter { $0.isShot && !$0.isOverlay }
    }
}

struct ChannelMetadata: Identifiable, Hashable {
    let index: Int
    var id: Int { index }

    var name: String
    var isShot: Bool
    var isOverlay: Bool
    var pseudoColor: String?
    var pixelMode: String?
    var cameraGain: Int?
    var cameraGainUnit: String?
    var exposureSeconds: Double?
}

struct PixelSize: Codable, Hashable, Sendable {
    var width: Int
    var height: Int

    var description: String {
        "\(width) x \(height)"
    }
}

extension DateFormatter {
    static let metadataDateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}
