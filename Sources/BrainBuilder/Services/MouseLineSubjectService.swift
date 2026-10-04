import CryptoKit
import Foundation
import Security

struct MouseLineEndpoint: Hashable, Sendable {
    static let production = MouseLineEndpoint(
        sshHost: "hhw9l84",
        sshRemotePort: 3_004,
        localForwardPort: 13_004
    )

    var sshHost: String
    var sshRemotePort: Int
    var localForwardPort: Int
}

struct MouseLineTokenVault {
    static let service = "org.brainbuilder.mouse-line"

    func load(account: String) throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: account,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else {
            throw MouseLineIntegrationError.keychain(Self.describe(status))
        }
        return token
    }

    func save(_ token: String, account: String) throws {
        guard !token.isEmpty, token.utf8.count <= 512 else {
            throw MouseLineIntegrationError.keychain("refused an empty or oversized token")
        }
        let identity: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: account,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: Data(token.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw MouseLineIntegrationError.keychain(Self.describe(updateStatus))
        }
        var newItem = identity
        attributes.forEach { newItem[$0.key] = $0.value }
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw MouseLineIntegrationError.keychain(Self.describe(addStatus))
        }
    }

    private static func describe(_ status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return message
        }
        return "OSStatus \(status)"
    }
}

private final class MouseLineNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

struct MouseLineSubjectService {
    private static let maximumResponseBytes = 1_048_576
    private static let expectedTopLevelKeys: Set<String> = [
        "schemaVersion", "service", "subject", "queryIdentifier", "matchedBy",
        "subjectRecordSha256", "usableForNavigation",
    ]
    private static let expectedSubjectKeys: Set<String> = [
        "publicId", "legacyId", "status", "sex", "dateOfBirth", "genotype",
        "mouseUser", "updatedAt", "cage", "surgeries",
    ]
    private static let expectedCageKeys: Set<String> = [
        "cageCardId", "status", "room", "protocol",
    ]
    private static let expectedSurgeryKeys: Set<String> = [
        "date", "time", "operator", "type",
    ]

    let endpoint: MouseLineEndpoint
    private let tokenVault: MouseLineTokenVault
    private let session: URLSession

    init(
        endpoint: MouseLineEndpoint = .production,
        tokenVault: MouseLineTokenVault = MouseLineTokenVault()
    ) {
        self.endpoint = endpoint
        self.tokenVault = tokenVault
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 12
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.session = URLSession(
            configuration: configuration,
            delegate: MouseLineNoRedirectDelegate(),
            delegateQueue: nil
        )
    }

    func resolveSubject(
        identifier: String,
        suppliedToken: String?
    ) async throws -> MouseLineSubjectResolution {
        guard identifier == identifier.trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty,
              identifier.count <= 100 else {
            throw MouseLineIntegrationError.missingSubjectID
        }
        let token: String
        if let suppliedToken, !suppliedToken.isEmpty {
            token = suppliedToken
        } else if let saved = try tokenVault.load(account: endpoint.sshHost) {
            token = saved
        } else {
            throw MouseLineIntegrationError.missingToken
        }
        guard token.utf8.count <= 512 else {
            throw MouseLineIntegrationError.missingToken
        }

        // Reuse a forward already owned by Brain3D, another BrainBuilder window,
        // or an operator. A reachable HTTP error (including 401) proves the port
        // is occupied and must never trigger a competing ssh process.
        do {
            let data = try await requestSubject(identifier: identifier, token: token)
            return try Self.decodeAndValidate(data, expectedIdentifier: identifier)
        } catch {
            guard Self.shouldStartManagedTunnel(after: error) else {
                throw error
            }
        }

        let tunnel = try startTunnel()
        defer { stopTunnel(tunnel.process) }

        var lastTransportError: Error?
        for attempt in 0..<40 {
            try Task.checkCancellation()
            if !tunnel.process.isRunning {
                throw MouseLineIntegrationError.tunnel(tunnelFailureDetail(tunnel))
            }
            do {
                let data = try await requestSubject(identifier: identifier, token: token)
                return try Self.decodeAndValidate(data, expectedIdentifier: identifier)
            } catch let error as URLError where Self.isTunnelStartupError(error) {
                lastTransportError = error
                if attempt < 39 {
                    try await Task.sleep(nanoseconds: 100_000_000)
                    continue
                }
            }
        }
        let detail = (lastTransportError as? URLError)?.localizedDescription
            ?? "the local forward did not become ready"
        throw MouseLineIntegrationError.transport(detail)
    }

    func rememberSuppliedToken(_ token: String) throws {
        try tokenVault.save(token, account: endpoint.sshHost)
    }

    func makeReceipt(
        from resolution: MouseLineSubjectResolution,
        verifiedAt: Date = Date()
    ) -> ColonySubjectReceipt {
        ColonySubjectReceipt(
            schemaVersion: resolution.schemaVersion,
            service: resolution.service,
            publicId: resolution.subject.publicId,
            queryIdentifier: resolution.queryIdentifier,
            matchedBy: resolution.matchedBy,
            subjectRecordSha256: resolution.subjectRecordSha256,
            verifiedAt: verifiedAt,
            sshHost: endpoint.sshHost,
            sshRemotePort: endpoint.sshRemotePort,
            usableForNavigation: false
        )
    }

    static func decodeAndValidate(
        _ data: Data,
        expectedIdentifier: String
    ) throws -> MouseLineSubjectResolution {
        guard data.count <= maximumResponseBytes else {
            throw MouseLineIntegrationError.invalidResponse("response exceeds 1 MiB")
        }
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw MouseLineIntegrationError.invalidResponse("response is not JSON")
        }
        guard let object = raw as? [String: Any],
              Set(object.keys) == expectedTopLevelKeys,
              let subject = object["subject"] as? [String: Any],
              Set(subject.keys) == expectedSubjectKeys,
              let cage = subject["cage"] as? [String: Any],
              Set(cage.keys) == expectedCageKeys,
              let surgeries = subject["surgeries"] as? [[String: Any]],
              surgeries.allSatisfy({ Set($0.keys) == expectedSurgeryKeys }) else {
            throw MouseLineIntegrationError.invalidResponse("schema-1 members do not match the exact contract")
        }
        let resolution: MouseLineSubjectResolution
        do {
            resolution = try JSONDecoder().decode(MouseLineSubjectResolution.self, from: data)
        } catch {
            throw MouseLineIntegrationError.invalidResponse("schema-1 values could not be decoded")
        }
        guard resolution.schemaVersion == 1,
              resolution.service == "mouse_line",
              resolution.queryIdentifier == expectedIdentifier,
              !resolution.subject.publicId.isEmpty,
              resolution.usableForNavigation == false,
              isSHA256(resolution.subjectRecordSha256) else {
            throw MouseLineIntegrationError.invalidResponse("identity, query, boundary, or digest field is invalid")
        }
        let receiptMaterial: [String: Any] = [
            "schemaVersion": resolution.schemaVersion,
            "service": resolution.service,
            "subject": subject,
        ]
        let canonical = try canonicalJSON(receiptMaterial)
        let digest = SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        guard digest == resolution.subjectRecordSha256 else {
            throw MouseLineIntegrationError.invalidResponse("subjectRecordSha256 does not match the subject record")
        }
        return resolution
    }

    private func requestSubject(identifier: String, token: String) async throws -> Data {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = endpoint.localForwardPort
        components.path = "/api/v1/animals/resolve"
        components.queryItems = [URLQueryItem(name: "identifier", value: identifier)]
        guard let url = components.url else {
            throw MouseLineIntegrationError.transport("could not build the loopback URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MouseLineIntegrationError.transport("the service did not return HTTP")
        }
        guard data.count <= Self.maximumResponseBytes else {
            throw MouseLineIntegrationError.invalidResponse("response exceeds 1 MiB")
        }
        guard http.statusCode == 200 else {
            let error = (try? JSONDecoder().decode(MouseLineServerError.self, from: data))
            throw MouseLineIntegrationError.server(
                status: http.statusCode,
                code: error?.code ?? "http_\(http.statusCode)",
                detail: error?.detail ?? "The server returned HTTP \(http.statusCode)."
            )
        }
        return data
    }

    private func startTunnel() throws -> MouseLineTunnel {
        guard endpoint.sshHost.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil,
              (1...65_535).contains(endpoint.sshRemotePort),
              (1_024...65_535).contains(endpoint.localForwardPort) else {
            throw MouseLineIntegrationError.tunnel("the configured endpoint is invalid")
        }
        let process = Process()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-N", "-T",
            "-o", "BatchMode=yes",
            "-o", "ClearAllForwardings=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=2",
            "-L", "127.0.0.1:\(endpoint.localForwardPort):127.0.0.1:\(endpoint.sshRemotePort)",
            endpoint.sshHost,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw MouseLineIntegrationError.tunnel(error.localizedDescription)
        }
        return MouseLineTunnel(process: process, stderr: stderr)
    }

    private func stopTunnel(_ process: Process) {
        if process.isRunning {
            process.terminate()
        }
    }

    private func tunnelFailureDetail(_ tunnel: MouseLineTunnel) -> String {
        let data = (try? tunnel.stderr.fileHandleForReading.readToEnd()) ?? nil
        let text = data.flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let text, !text.isEmpty {
            return String(text.prefix(500))
        }
        return "ssh exited before the local forward became ready"
    }

    private static func isTunnelStartupError(_ error: URLError) -> Bool {
        switch error.code {
        case .cannotConnectToHost, .networkConnectionLost, .timedOut, .cannotFindHost:
            true
        default:
            false
        }
    }

    static func shouldStartManagedTunnel(after error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return urlError.code == .cannotConnectToHost
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
    }

    private static func canonicalJSON(_ value: Any) throws -> String {
        switch value {
        case is NSNull:
            return "null"
        case let string as String:
            let data = try JSONSerialization.data(
                withJSONObject: [string],
                options: [.withoutEscapingSlashes]
            )
            let wrapped = String(decoding: data, as: UTF8.self)
            return String(wrapped.dropFirst().dropLast())
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            guard number.doubleValue.isFinite else {
                throw MouseLineIntegrationError.invalidResponse("canonical JSON contains a non-finite number")
            }
            return number.stringValue
        case let array as [Any]:
            return "[" + (try array.map(canonicalJSON)).joined(separator: ",") + "]"
        case let dictionary as [String: Any]:
            return "{" + (try dictionary.keys.sorted().map { key in
                try canonicalJSON(key) + ":" + canonicalJSON(dictionary[key] as Any)
            }).joined(separator: ",") + "}"
        default:
            throw MouseLineIntegrationError.invalidResponse("canonical JSON contains an unsupported value")
        }
    }
}

private struct MouseLineServerError: Decodable {
    var schemaVersion: Int?
    var code: String
    var detail: String
}

private struct MouseLineTunnel {
    var process: Process
    var stderr: Pipe
}
