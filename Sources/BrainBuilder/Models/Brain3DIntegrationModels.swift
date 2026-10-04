import Foundation

enum StrictJSONValue: Codable, Hashable, Sendable {
    case object([String: StrictJSONValue])
    case array([StrictJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Double.self) {
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Brain3D JSON numbers must be finite"
                )
            }
            self = .number(value)
        } else if let value = try? container.decode([StrictJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: StrictJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(
                    value,
                    .init(codingPath: encoder.codingPath, debugDescription: "JSON numbers must be finite")
                )
            }
            try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var objectValue: [String: StrictJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [StrictJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var integerValue: Int? {
        guard case .number(let value) = self,
              value.rounded() == value,
              value >= Double(Int.min),
              value <= Double(Int.max) else { return nil }
        return Int(value)
    }
}

struct Brain3DHistologyHandoff: Codable, Hashable, Sendable {
    var raw: [String: StrictJSONValue]

    init(raw: [String: StrictJSONValue]) {
        self.raw = raw
    }

    init(from decoder: Decoder) throws {
        let value = try StrictJSONValue(from: decoder)
        guard case .object(let raw) = value else {
            throw DecodingError.typeMismatch(
                [String: StrictJSONValue].self,
                .init(codingPath: decoder.codingPath, debugDescription: "Histology handoff must be an object")
            )
        }
        self.raw = raw
    }

    func encode(to encoder: Encoder) throws {
        try StrictJSONValue.object(raw).encode(to: encoder)
    }

    func string(_ keys: String...) -> String? {
        keys.lazy.compactMap { raw[$0]?.stringValue }.first
    }

    func integer(_ keys: String...) -> Int? {
        keys.lazy.compactMap { raw[$0]?.integerValue }.first
    }

    var handoffID: String? {
        string("handoff_id", "handoffId")
    }

    var handoffSHA256: String? {
        string("handoff_sha256", "canonical_sha256", "handoffSha256", "canonicalSha256")
    }

    var subjectID: String? {
        if let direct = string("subject_id", "subjectId") { return direct }
        return raw["subject"]?.objectValue?["subject_id"]?.stringValue
    }

    var sourceProjectID: String? {
        if let direct = string("source_project_id", "project_uuid", "sourceProjectId", "projectUuid") {
            return direct
        }
        return raw["project"]?.objectValue?["project_uuid"]?.stringValue
    }

    var sourceProjectRevision: Int? {
        if let direct = integer(
            "source_project_revision", "project_revision", "sourceProjectRevision", "projectRevision"
        ) {
            return direct
        }
        return raw["project"]?.objectValue?["project_revision"]?.integerValue
    }
}

struct Brain3DHistologyDocument: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var lockedHandoffs: [Brain3DHistologyHandoff]
    var brainbuilderEvidence: [StrictJSONValue]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case lockedHandoffs = "locked_handoffs"
        case brainbuilderEvidence = "brainbuilder_evidence"
    }
}

struct Brain3DPlanImport: Hashable, Sendable {
    var packageURL: URL
    var projectID: String
    var projectRevision: Int
    var subjectID: String
    var handoffs: [Brain3DHistologyHandoff]
    var histologySHA256: String
}

enum Brain3DIntegrationError: LocalizedError {
    case invalidPackage(String)
    case unsupportedSchema(String)
    case checksumMismatch(String)
    case atlasMismatch(String)
    case subjectBindingRequired(planSubjectID: String, datasetSubjectID: String?)

    var errorDescription: String? {
        switch self {
        case .invalidPackage(let detail): "Invalid Brain3D package: \(detail)"
        case .unsupportedSchema(let detail): "Unsupported Brain3D schema: \(detail)"
        case .checksumMismatch(let detail): "Brain3D checksum validation failed: \(detail)"
        case .atlasMismatch(let detail): "Brain3D atlas mismatch: \(detail)"
        case .subjectBindingRequired(let planSubjectID, let datasetSubjectID):
            "Subject confirmation is required: plan=\(planSubjectID), dataset=\(datasetSubjectID ?? "missing")"
        }
    }
}
