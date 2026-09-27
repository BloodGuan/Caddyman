import Foundation
import OSLog

enum CaddyBinaryResolutionError: Error, LocalizedError, Equatable {
    case notFound
    case notExecutable(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            L10n.text("Caddy was not found in the standard Homebrew locations. Choose an existing Caddy executable in Settings.")
        case .notExecutable(let path):
            L10n.format("The selected Caddy path is missing or is not executable: %@", path)
        }
    }
}

protocol ExecutableChecking: Sendable {
    func isExecutableFile(atPath path: String) -> Bool
}

struct SystemExecutableChecker: ExecutableChecking {
    func isExecutableFile(atPath path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}

protocol CaddyBinaryLocating: Sendable {
    func locate(explicitPath: String) throws -> URL
}

struct CaddyBinaryLocator: CaddyBinaryLocating {
    static let homebrewPaths = [
        "/opt/homebrew/bin/caddy",
        "/usr/local/bin/caddy",
    ]

    private let executableChecker: any ExecutableChecking
    private let candidatePaths: [String]

    init(
        executableChecker: any ExecutableChecking = SystemExecutableChecker(),
        candidatePaths: [String] = CaddyBinaryLocator.homebrewPaths
    ) {
        self.executableChecker = executableChecker
        self.candidatePaths = candidatePaths
    }

    func locate(explicitPath: String) throws -> URL {
        let trimmedPath = explicitPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPath.isEmpty {
            guard executableChecker.isExecutableFile(atPath: trimmedPath) else {
                throw CaddyBinaryResolutionError.notExecutable(trimmedPath)
            }
            return URL(fileURLWithPath: trimmedPath).standardizedFileURL
        }

        if let candidate = candidatePaths.first(where: { executableChecker.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: candidate).standardizedFileURL
        }
        throw CaddyBinaryResolutionError.notFound
    }
}

enum DNSPodModuleStatus: Equatable, Sendable {
    case available
    case missing
    case unknown(String)

    var title: String {
        switch self {
        case .available: L10n.text("Available")
        case .missing: L10n.text("Not installed")
        case .unknown: L10n.text("Could not detect")
        }
    }

    var detail: String {
        switch self {
        case .available:
            L10n.text("This binary reports dns.providers.dnspod.")
        case .missing:
            L10n.text("This Caddy binary does not report dns.providers.dnspod. DNSPod DNS-01 will be unavailable.")
        case .unknown(let reason):
            reason
        }
    }
}

struct CaddyInstallationInfo: Equatable, Sendable {
    let binaryURL: URL
    let version: String
    let dnsPodStatus: DNSPodModuleStatus
    let moduleCount: Int?
    let checkedAt: Date
}

enum CaddyInspectionState: Equatable {
    case notChecked
    case checking
    case noBinaryFound
    case invalidSelectedPath(String)
    case ready(CaddyInstallationInfo)
    case failed(String)
}

enum CaddyModuleListParseError: Error, Equatable, LocalizedError {
    case emptyOutput
    case invalidJSON
    case unsupportedFormat
    case emptyModuleList

    var errorDescription: String? {
        switch self {
        case .emptyOutput: L10n.text("Caddy returned an empty module list.")
        case .invalidJSON: L10n.text("Caddy returned data that is not valid JSON.")
        case .unsupportedFormat: L10n.text("This Caddy version returned an unsupported module-list format.")
        case .emptyModuleList: L10n.text("Caddy returned a valid but empty module list.")
        }
    }
}

enum CaddyModuleListParser {
    static let dnsPodModuleID = "dns.providers.dnspod"

    static func parseModuleIDs(from data: Data) throws -> Set<String> {
        guard !data.isEmpty else { throw CaddyModuleListParseError.emptyOutput }

        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw CaddyModuleListParseError.invalidJSON
        }

        guard let moduleIDs = moduleIDs(in: json) else {
            throw CaddyModuleListParseError.unsupportedFormat
        }
        guard !moduleIDs.isEmpty else { throw CaddyModuleListParseError.emptyModuleList }
        return Set(moduleIDs)
    }

    private static func moduleIDs(in value: Any) -> [String]? {
        if let values = value as? NSArray {
            var ids: [String] = []
            ids.reserveCapacity(values.count)

            for value in values {
                if let id = value as? String {
                    ids.append(id)
                    continue
                }
                guard let object = value as? NSDictionary, let id = moduleID(in: object) else {
                    return nil
                }
                ids.append(id)
            }
            return ids
        }

        if let object = value as? [String: Any] {
            if let nested = object["modules"] {
                return moduleIDs(in: nested)
            }

            let keys = Array(object.keys)
            if !keys.isEmpty, keys.allSatisfy({ $0.contains(".") }) {
                return keys
            }
        }

        return nil
    }

    private static func moduleID(in object: NSDictionary) -> String? {
        for key in ["id", "ID", "module", "name", "module_name"] {
            if let value = object[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

protocol CaddyBinaryInspecting: Sendable {
    func inspect(binaryURL: URL) async throws -> CaddyInstallationInfo
}

struct CaddyBinaryInspector: CaddyBinaryInspecting {
    private let processRunner: any ProcessRunning

    init(processRunner: any ProcessRunning = FoundationProcessRunner()) {
        self.processRunner = processRunner
    }

    func inspect(binaryURL: URL) async throws -> CaddyInstallationInfo {
        let versionResult = try await processRunner.run(
            ProcessRequest(executableURL: binaryURL, arguments: ["version"])
        )
        CaddyProcessDiagnostics.record(command: "version", result: versionResult)

        guard versionResult.exitCode == 0 else {
            throw CaddyBinaryInspectionError.versionCommandFailed(versionResult.exitCode)
        }
        guard let version = versionResult.stdout
            .components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw CaddyBinaryInspectionError.emptyVersion
        }

        let moduleResult: ProcessResult
        do {
            moduleResult = try await processRunner.run(
                ProcessRequest(executableURL: binaryURL, arguments: ["list-modules", "--json"])
            )
        } catch {
            return CaddyInstallationInfo(
                binaryURL: binaryURL,
                version: version,
                dnsPodStatus: .unknown(L10n.format("Caddy version was detected, but the module query failed: %@", error.localizedDescription)),
                moduleCount: nil,
                checkedAt: Date()
            )
        }

        CaddyProcessDiagnostics.record(command: "list-modules --json", result: moduleResult)
        guard moduleResult.exitCode == 0 else {
            return CaddyInstallationInfo(
                binaryURL: binaryURL,
                version: version,
                dnsPodStatus: .unknown(L10n.format("Caddy version was detected, but list-modules exited with status %d.", Int(moduleResult.exitCode))),
                moduleCount: nil,
                checkedAt: Date()
            )
        }

        do {
            let moduleIDs = try CaddyModuleListParser.parseModuleIDs(from: Data(moduleResult.stdout.utf8))
            let status: DNSPodModuleStatus = moduleIDs.contains(CaddyModuleListParser.dnsPodModuleID)
                ? .available
                : .missing
            return CaddyInstallationInfo(
                binaryURL: binaryURL,
                version: version,
                dnsPodStatus: status,
                moduleCount: moduleIDs.count,
                checkedAt: Date()
            )
        } catch {
            return CaddyInstallationInfo(
                binaryURL: binaryURL,
                version: version,
                dnsPodStatus: .unknown(error.localizedDescription),
                moduleCount: nil,
                checkedAt: Date()
            )
        }
    }
}

enum CaddyBinaryInspectionError: Error, LocalizedError {
    case versionCommandFailed(Int32)
    case emptyVersion

    var errorDescription: String? {
        switch self {
        case .versionCommandFailed(let status):
            L10n.format("Caddy version command exited with status %d. Check the selected binary.", Int(status))
        case .emptyVersion:
            L10n.text("Caddy returned an empty version string.")
        }
    }
}

private enum CaddyProcessDiagnostics {
    private static let logger = Logger(subsystem: "com.blood.caddyman", category: "Caddy CLI")

    static func record(command: String, result: ProcessResult) {
        let stdout = redacted(result.stdout) + (result.stdoutWasTruncated ? " [truncated]" : "")
        let stderr = redacted(result.stderr) + (result.stderrWasTruncated ? " [truncated]" : "")
        logger.debug("Caddy \(command, privacy: .public), exit \(result.exitCode, privacy: .public); stdout: \(stdout, privacy: .private); stderr: \(stderr, privacy: .private)")
    }

    private static func redacted(_ value: String) -> String {
        var result = String(value.prefix(4_000))
        let patterns = [
            #"(?i)(token|password|secret|api[_-]?key)(\s*[:=]\s*)("[^"]*"|'[^']*'|[^\s,}]+)"#,
            #"(?i)(https?://)[^/@\s:]+:[^/@\s]+@"#,
        ]
        result = result.replacingOccurrences(of: patterns[0], with: "$1=<redacted>", options: .regularExpression)
        result = result.replacingOccurrences(of: patterns[1], with: "$1<redacted>@", options: .regularExpression)
        return result
    }
}
