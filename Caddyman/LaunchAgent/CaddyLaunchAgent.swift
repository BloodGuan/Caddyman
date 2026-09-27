import Foundation
import Darwin

struct CaddyLaunchAgentConfiguration: Equatable, Sendable {
    let launcherURL: URL
    let binaryURL: URL
    let caddyfileURL: URL
}

struct CaddyLaunchAgentSnapshot: Equatable, Sendable {
    let isInstalled: Bool
    let isRunning: Bool
    let isDisabled: Bool
    let pid: Int32?
    let configuration: CaddyLaunchAgentConfiguration?
    let issue: String?
    let isForeign: Bool

    static let notInstalled = CaddyLaunchAgentSnapshot(
        isInstalled: false, isRunning: false, isDisabled: false,
        pid: nil, configuration: nil, issue: nil, isForeign: false
    )
}

enum CaddyLaunchAgentError: Error, LocalizedError, Equatable {
    case foreignAgent
    case notInstalled
    case invalidConfiguration
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .foreignAgent:
            L10n.text("A different LaunchAgent already uses Caddyman's service label or plist path. Caddyman will not change it.")
        case .notInstalled:
            L10n.text("Caddyman's Caddy LaunchAgent is not installed.")
        case .invalidConfiguration:
            L10n.text("The LaunchAgent configuration is incomplete or unsafe.")
        case .commandFailed(let detail):
            L10n.format("Could not manage the Caddyman LaunchAgent: %@", detail)
        }
    }
}

enum CaddyLaunchAgentPlist {
    static let label = "com.blood.caddyman.caddy"
    static let launcherFlag = "--caddyman-launch-caddy"

    static func render(_ configuration: CaddyLaunchAgentConfiguration) throws -> Data {
        guard configuration.launcherURL.isFileURL,
              configuration.binaryURL.isFileURL,
              configuration.caddyfileURL.isFileURL,
              configuration.launcherURL.path.hasPrefix("/"),
              configuration.binaryURL.path.hasPrefix("/"),
              configuration.caddyfileURL.path.hasPrefix("/") else {
            throw CaddyLaunchAgentError.invalidConfiguration
        }
        let plist: [String: Any] = [
            "Label": label,
            "CaddymanManagedVersion": 1,
            "ProgramArguments": [
                configuration.launcherURL.path,
                launcherFlag,
                "--binary", configuration.binaryURL.path,
                "--config", configuration.caddyfileURL.path,
            ],
            "WorkingDirectory": configuration.caddyfileURL.deletingLastPathComponent().path,
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 30,
            "ProcessType": "Background",
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": "/dev/null",
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    static func readOwnedConfiguration(from data: Data) throws -> CaddyLaunchAgentConfiguration {
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["Label"] as? String == label,
              plist["CaddymanManagedVersion"] as? Int == 1,
              let args = plist["ProgramArguments"] as? [String],
              args.count == 6,
              args[1] == launcherFlag,
              args[2] == "--binary",
              args[4] == "--config",
              args[0].hasPrefix("/"), args[3].hasPrefix("/"), args[5].hasPrefix("/"),
              URL(fileURLWithPath: args[0]).lastPathComponent == "Caddyman",
              plist["WorkingDirectory"] as? String == URL(fileURLWithPath: args[5]).deletingLastPathComponent().path,
              plist["RunAtLoad"] as? Bool == true,
              let keepAlive = plist["KeepAlive"] as? [String: Bool],
              keepAlive == ["SuccessfulExit": false],
              plist["EnvironmentVariables"] == nil,
              plist["StandardOutPath"] as? String == "/dev/null",
              plist["StandardErrorPath"] as? String == "/dev/null" else {
            throw CaddyLaunchAgentError.foreignAgent
        }
        return CaddyLaunchAgentConfiguration(
            launcherURL: URL(fileURLWithPath: args[0]).standardizedFileURL,
            binaryURL: URL(fileURLWithPath: args[3]).standardizedFileURL,
            caddyfileURL: URL(fileURLWithPath: args[5]).standardizedFileURL
        )
    }
}

@MainActor
protocol CaddyLaunchAgentControlling: AnyObject {
    func inspect() async -> CaddyLaunchAgentSnapshot
    func installAndStart(_ configuration: CaddyLaunchAgentConfiguration) async throws
    func uninstall() async throws
    func start() async throws
    func stop() async throws
    func restart() async throws
    func reload(configuration: CaddyLaunchAgentConfiguration, environment: [String: String], secrets: [String]) async throws
}

@MainActor
final class CaddyLaunchAgentController: CaddyLaunchAgentControlling {
    private let runner: any ProcessRunning
    private let agentURL: URL
    private let domain: String
    private let serviceTarget: String

    init(
        runner: any ProcessRunning = FoundationProcessRunner(),
        agentURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(CaddyLaunchAgentPlist.label).plist"),
        uid: uid_t = getuid()
    ) {
        self.runner = runner
        self.agentURL = agentURL
        self.domain = "gui/\(uid)"
        self.serviceTarget = "gui/\(uid)/\(CaddyLaunchAgentPlist.label)"
    }

    func inspect() async -> CaddyLaunchAgentSnapshot {
        let configuration: CaddyLaunchAgentConfiguration
        do {
            guard FileManager.default.fileExists(atPath: agentURL.path) else {
                return .notInstalled
            }
            configuration = try CaddyLaunchAgentPlist.readOwnedConfiguration(from: Data(contentsOf: agentURL))
        } catch {
            return CaddyLaunchAgentSnapshot(isInstalled: false, isRunning: false, isDisabled: false,
                pid: nil, configuration: nil, issue: CaddyLaunchAgentError.foreignAgent.localizedDescription,
                isForeign: true)
        }

        let printResult = try? await command(["print", serviceTarget], acceptsFailure: true)
        let detail = printResult?.stdout ?? ""
        if printResult?.exitCode == 0 {
            let loadedPath = Self.firstValue(in: detail, key: "path")
            let loadedProgram = Self.firstValue(in: detail, key: "program")
            guard loadedPath == agentURL.path,
                  loadedProgram == configuration.launcherURL.path else {
                return CaddyLaunchAgentSnapshot(isInstalled: false, isRunning: false, isDisabled: false,
                    pid: nil, configuration: nil,
                    issue: CaddyLaunchAgentError.foreignAgent.localizedDescription, isForeign: true)
            }
        }
        let pid = Self.firstInt32(in: detail, pattern: #"(?m)^\s*pid = (\d+)\s*$"#)
        let lastExit = Self.firstInt32(in: detail, pattern: #"(?m)^\s*last exit code = (-?\d+)\s*$"#)
        let disabledResult = try? await command(["print-disabled", domain], acceptsFailure: true)
        let isDisabled = disabledResult?.stdout.contains("\"\(CaddyLaunchAgentPlist.label)\" => disabled") == true
        let issue = lastExit.flatMap { $0 == 0 ? nil : L10n.format("Last service exit code: %d", Int($0)) }
        return CaddyLaunchAgentSnapshot(
            isInstalled: true, isRunning: pid != nil, isDisabled: isDisabled,
            pid: pid, configuration: configuration, issue: issue, isForeign: false
        )
    }

    func installAndStart(_ configuration: CaddyLaunchAgentConfiguration) async throws {
        let data = try CaddyLaunchAgentPlist.render(configuration)
        let current = await inspect()
        if current.isForeign {
            throw CaddyLaunchAgentError.foreignAgent
        }
        let previousData = current.isInstalled ? try Data(contentsOf: agentURL) : nil
        if current.isInstalled {
            _ = try await command(["disable", serviceTarget])
            try await bootoutIfLoaded()
        } else {
            let existingJob = try await command(["print", serviceTarget], acceptsFailure: true)
            guard existingJob.exitCode != 0 else { throw CaddyLaunchAgentError.foreignAgent }
        }
        do {
            try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: agentURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: agentURL.path)
            _ = try await command(["enable", serviceTarget])
            _ = try await command(["bootstrap", domain, agentURL.path])
        } catch {
            let originalError = error
            do {
                try await bootoutIfLoaded()
                if let previousData {
                    try previousData.write(to: agentURL, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: agentURL.path)
                    if current.isDisabled {
                        _ = try await command(["disable", serviceTarget])
                    } else {
                        _ = try await command(["enable", serviceTarget])
                        _ = try await command(["bootstrap", domain, agentURL.path])
                    }
                } else if FileManager.default.fileExists(atPath: agentURL.path) {
                    try FileManager.default.removeItem(at: agentURL)
                    _ = try await command(["disable", serviceTarget])
                }
            } catch {
                throw CaddyLaunchAgentError.commandFailed(
                    L10n.text("The update failed and the previous service could not be restored."))
            }
            throw originalError
        }
    }

    func uninstall() async throws {
        let current = await inspect()
        guard current.isInstalled else {
            if current.isForeign { throw CaddyLaunchAgentError.foreignAgent }
            return
        }
        _ = try await command(["disable", serviceTarget])
        try await bootoutIfLoaded()
        try FileManager.default.removeItem(at: agentURL)
    }

    func start() async throws {
        let current = await inspect()
        if current.isForeign { throw CaddyLaunchAgentError.foreignAgent }
        guard current.isInstalled else { throw CaddyLaunchAgentError.notInstalled }
        _ = try await command(["enable", serviceTarget])
        if (try await command(["print", serviceTarget], acceptsFailure: true)).exitCode != 0 {
            _ = try await command(["bootstrap", domain, agentURL.path])
        } else if !current.isRunning {
            _ = try await command(["kickstart", serviceTarget])
        }
    }

    func stop() async throws {
        let current = await inspect()
        if current.isForeign { throw CaddyLaunchAgentError.foreignAgent }
        guard current.isInstalled else { throw CaddyLaunchAgentError.notInstalled }
        _ = try await command(["disable", serviceTarget])
        try await bootoutIfLoaded()
    }

    func restart() async throws {
        let current = await inspect()
        if current.isForeign { throw CaddyLaunchAgentError.foreignAgent }
        guard current.isInstalled else { throw CaddyLaunchAgentError.notInstalled }
        _ = try await command(["enable", serviceTarget])
        if (try await command(["print", serviceTarget], acceptsFailure: true)).exitCode == 0 {
            _ = try await command(["kickstart", "-k", serviceTarget])
        } else {
            _ = try await command(["bootstrap", domain, agentURL.path])
        }
    }

    func reload(configuration: CaddyLaunchAgentConfiguration, environment: [String: String], secrets: [String]) async throws {
        let current = await inspect()
        guard current.isInstalled, current.isRunning, current.configuration == configuration else {
            throw CaddyLaunchAgentError.invalidConfiguration
        }
        let result = try await runner.run(ProcessRequest(
            executableURL: configuration.binaryURL,
            arguments: ["reload", "--config", configuration.caddyfileURL.path, "--adapter", "caddyfile"],
            timeout: 15,
            workingDirectoryURL: configuration.caddyfileURL.deletingLastPathComponent(),
            environment: environment,
            environmentVariablesToRemove: ["DNSPOD_TOKEN", "CADDY_ADMIN"]
        ))
        guard result.exitCode == 0 else {
            let output = result.stderr.isEmpty ? result.stdout : result.stderr
            let detail = secrets.filter { !$0.isEmpty }.reduce(CaddyfileDocument.redactingCredentials(in: output)) {
                $0.replacingOccurrences(of: $1, with: "[REDACTED]")
            }
            throw CaddyRuntimeError.reloadFailed(detail)
        }
    }

    @discardableResult
    private func command(_ arguments: [String], acceptsFailure: Bool = false) async throws -> ProcessResult {
        let result = try await runner.run(ProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: arguments, timeout: 10, outputLimitBytes: 16 * 1024,
            environmentVariablesToRemove: ["DNSPOD_TOKEN", "CADDY_ADMIN"]
        ))
        if !acceptsFailure, result.exitCode != 0 {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CaddyLaunchAgentError.commandFailed(detail.isEmpty ? "launchctl exited with \(result.exitCode)" : detail)
        }
        return result
    }

    private func bootoutIfLoaded() async throws {
        let loaded = try await command(["print", serviceTarget], acceptsFailure: true)
        guard loaded.exitCode == 0 else { return }
        let configuration = try CaddyLaunchAgentPlist.readOwnedConfiguration(from: Data(contentsOf: agentURL))
        guard Self.firstValue(in: loaded.stdout, key: "path") == agentURL.path,
              Self.firstValue(in: loaded.stdout, key: "program") == configuration.launcherURL.path else {
            throw CaddyLaunchAgentError.foreignAgent
        }
        _ = try await command(["bootout", domain, agentURL.path])
    }

    private static func firstInt32(in text: String, pattern: String) -> Int32? {
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        let line = String(text[range])
        return Int32(line.split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? "")
    }

    private static func firstValue(in text: String, key: String) -> String? {
        text.components(separatedBy: .newlines)
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(key) = ") }?
            .trimmingCharacters(in: .whitespaces)
            .dropFirst(key.count + 3)
            .description
    }
}
