import Foundation

enum MouseLineIdentifierMatch: String, Codable, Hashable, Sendable {
    case publicId
    case legacyId
}

struct MouseLineCage: Codable, Hashable, Sendable {
    var cageCardId: String
    var status: String
    var room: String?
    var `protocol`: String?
}

struct MouseLineSurgery: Codable, Hashable, Sendable {
    var date: String?
    var time: String?
    var operatorLabel: String?
    var type: String?

    enum CodingKeys: String, CodingKey {
        case date
        case time
        case operatorLabel = "operator"
        case type
    }
}

struct MouseLineSubject: Codable, Hashable, Sendable {
    var publicId: String
    var legacyId: String?
    var status: String
    var sex: String?
    var dateOfBirth: String?
    var genotype: String?
    var mouseUser: String?
    var updatedAt: String
    var cage: MouseLineCage
    var surgeries: [MouseLineSurgery]
}

/// Full, transient response used for reviewer confirmation. It is deliberately
/// not embedded in a registration project; only `ColonySubjectReceipt` is.
struct MouseLineSubjectResolution: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var service: String
    var subject: MouseLineSubject
    var queryIdentifier: String
    var matchedBy: MouseLineIdentifierMatch
    var subjectRecordSha256: String
    var usableForNavigation: Bool

    func isExactPublicIDMatch(for projectSubjectID: String) -> Bool {
        matchedBy == .publicId
            && queryIdentifier == projectSubjectID
            && subject.publicId == projectSubjectID
    }
}

/// Compact, non-secret proof that the registration subject was resolved against
/// the read-only colony service. This is identity evidence, never navigation input.
struct ColonySubjectReceipt: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var service: String
    var publicId: String
    var queryIdentifier: String
    var matchedBy: MouseLineIdentifierMatch
    var subjectRecordSha256: String
    var verifiedAt: Date
    var sshHost: String
    var sshRemotePort: Int
    var usableForNavigation: Bool
}

enum MouseLineIntegrationError: LocalizedError, Equatable {
    case missingSubjectID
    case missingToken
    case keychain(String)
    case tunnel(String)
    case transport(String)
    case server(status: Int, code: String, detail: String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingSubjectID:
            "Set an exact project subject ID before checking the colony system."
        case .missingToken:
            "Enter the mouse_line integration token (or verify once to save it in Keychain)."
        case .keychain(let detail):
            "Could not access the mouse_line token in Keychain: \(detail)"
        case .tunnel(let detail):
            "Could not open the mouse_line SSH tunnel: \(detail)"
        case .transport(let detail):
            "Could not reach mouse_line through the SSH tunnel: \(detail)"
        case .server(_, let code, let detail):
            "mouse_line rejected the request (\(code)): \(detail)"
        case .invalidResponse(let detail):
            "mouse_line returned an invalid subject receipt: \(detail)"
        }
    }
}
