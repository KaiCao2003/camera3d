import Foundation

struct ABBAReviewPreview: Decodable, Identifiable {
    var schemaVersion: Int
    var stage: String
    var resultPath: String
    var statePath: String
    var slices: [ABBAReviewSlice]
    var messages: [String]

    var id: String { resultPath }

    static func read(from url: URL) throws -> Self {
        let preview = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard preview.schemaVersion == 1, !preview.slices.isEmpty else {
            throw RegistrationWorkerError.resultReadFailed("Unsupported or empty ABBA review")
        }
        return preview
    }
}

struct ABBAReviewSlice: Decodable, Identifiable {
    var id: String
    var title: String
    var histologyPath: String
    var atlasPath: String
    var overlayPath: String
}
