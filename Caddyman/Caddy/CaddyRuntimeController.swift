import Foundation

enum CaddyRuntimeError: Error, LocalizedError {
    case alreadyRunning
    case externalAdminAPI
    case notRunning
    case startFailed
    case startHealthCheckFailed
    case reloadFailed(String)
    case stopFailed

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            L10n.text("Caddyman already has a Caddy process running.")
        case .externalAdminAPI:
            L10n.text("127.0.0.1:2019 already accepts connections. Caddyman will not take over a process whose ownership is unknown.")
        case .notRunning:
            L10n.text("Caddyman does not own a running Caddy process to reload.")
        case .startFailed:
            L10n.text("Caddyman could not start its Caddy process. Check the Caddyfile and binary.")
        case .startHealthCheckFailed:
            L10n.text("Caddy started but did not open its loopback Admin API. Caddyman stopped its process.")
        case .reloadFailed(let detail):
            L10n.format("Caddy rejected the reload: %@", detail)
        case .stopFailed:
            L10n.text("Caddyman could not stop the Caddy process it started.")
        }
    }
}

@MainActor
protocol CaddyRuntimeControlling: AnyObject {
    var isRunning: Bool { get }
    var configurationPath: String? { get }
    func start(
        binaryURL: URL,
        configurationURL: URL,
        environment: [String: String],
        secrets: [String],
        outputHandler: @escaping @MainActor @Sendable (String) -> Void
    ) throws
    func stop() async throws
    func reload(binaryURL: URL, configurationURL: URL, environment: [String: String], secrets: [String]) async throws
}

@MainActor
final class CaddySessionRuntimeController: CaddyRuntimeControlling {
    private var process: Process?
    private var logRedactor: RuntimeSecretRedactor?
    private(set) var configurationPath: String?

    var isRunning: Bool {
        process?.isRunning == true
    }

    func start(
        binaryURL: URL,
        configurationURL: URL,
        environment: [String: String],
        secrets: [String],
        outputHandler: @escaping @MainActor @Sendable (String) -> Void
    ) throws {
        guard !isRunning else { throw CaddyRuntimeError.alreadyRunning }
        let child = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let logRedactor = RuntimeSecretRedactor(secrets: secrets)
        Self.captureOutput(from: stdout.fileHandleForReading, redactor: logRedactor, outputHandler: outputHandler)
        Self.captureOutput(from: stderr.fileHandleForReading, redactor: logRedactor, outputHandler: outputHandler)
        child.executableURL = binaryURL
        child.arguments = ["run", "--config", configurationURL.path, "--adapter", "caddyfile"]
        child.currentDirectoryURL = configurationURL.deletingLastPathComponent()
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = stdout
        child.standardError = stderr
        var childEnvironment = ProcessInfo.processInfo.environment
        childEnvironment.removeValue(forKey: "DNSPOD_TOKEN")
        childEnvironment.removeValue(forKey: "CADDY_ADMIN")
        child.environment = childEnvironment.merging(environment) { _, override in override }
        do {
            try child.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw CaddyRuntimeError.startFailed
        }
        process = child
        self.logRedactor = logRedactor
        configurationPath = configurationURL.standardizedFileURL.path
    }

    func stop() async throws {
        guard let process, process.isRunning else {
            self.process = nil
            logRedactor = nil
            configurationPath = nil
            throw CaddyRuntimeError.notRunning
        }
        process.terminate()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while process.isRunning && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard !process.isRunning else { throw CaddyRuntimeError.stopFailed }
        self.process = nil
        logRedactor = nil
        configurationPath = nil
    }

    func reload(
        binaryURL: URL,
        configurationURL: URL,
        environment: [String: String],
        secrets: [String]
    ) async throws {
        guard isRunning,
              configurationPath == configurationURL.standardizedFileURL.path else {
            throw CaddyRuntimeError.notRunning
        }
        logRedactor?.add(secrets: secrets)
        let result: ProcessResult
        do {
            result = try await FoundationProcessRunner().run(ProcessRequest(
                executableURL: binaryURL,
                arguments: ["reload", "--config", configurationURL.path, "--adapter", "caddyfile"],
                timeout: 15,
                workingDirectoryURL: configurationURL.deletingLastPathComponent(),
                environment: environment,
                environmentVariablesToRemove: ["DNSPOD_TOKEN", "CADDY_ADMIN"]
            ))
        } catch {
            throw CaddyRuntimeError.reloadFailed(Self.redact(error.localizedDescription, secrets: secrets))
        }
        guard result.exitCode == 0 else {
            let output = [result.stderr, result.stdout]
                .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? L10n.format("Caddy validation failed with exit status %d.", Int(result.exitCode))
            throw CaddyRuntimeError.reloadFailed(Self.redact(output, secrets: secrets))
        }
    }

    private static func redact(_ text: String, secrets: [String]) -> String {
        secrets.reduce(CaddyfileDocument.redactingCredentials(in: text)) { output, secret in
            guard !secret.isEmpty else { return output }
            return output.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
    }

    private static func captureOutput(
        from handle: FileHandle,
        redactor: RuntimeSecretRedactor,
        outputHandler: @escaping @MainActor @Sendable (String) -> Void
    ) {
        let lineReader = RedactedCaddyLogLineReader(redactor: redactor, outputHandler: outputHandler)
        handle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                lineReader.finish()
            } else {
                lineReader.append(data)
            }
        }
    }
}

private final class RedactedCaddyLogLineReader: @unchecked Sendable {
    private let lock = NSLock()
    private let redactor: RuntimeSecretRedactor
    private let outputHandler: @MainActor @Sendable (String) -> Void
    private var pending = Data()

    init(redactor: RuntimeSecretRedactor, outputHandler: @escaping @MainActor @Sendable (String) -> Void) {
        self.redactor = redactor
        self.outputHandler = outputHandler
    }

    func append(_ data: Data) {
        consume(data, finish: false)
    }

    func finish() {
        consume(Data(), finish: true)
    }

    private func consume(_ data: Data, finish: Bool) {
        lock.lock()
        pending.append(data)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(Data(pending[..<newline]))
            pending.removeSubrange(...newline)
        }
        if finish, !pending.isEmpty {
            lines.append(pending)
            pending.removeAll(keepingCapacity: false)
        }
        lock.unlock()

        for lineData in lines {
            let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .newlines)
            guard !line.isEmpty else { continue }
            let safeLine = redactor.redact(line)
            Task { @MainActor in outputHandler(safeLine) }
        }
    }
}

final class RuntimeSecretRedactor: @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: Set<String>

    init(secrets: [String]) {
        self.secrets = Set(secrets.filter { !$0.isEmpty })
    }

    func add(secrets: [String]) {
        lock.lock()
        self.secrets.formUnion(secrets.filter { !$0.isEmpty })
        lock.unlock()
    }

    func redact(_ line: String) -> String {
        lock.lock()
        let values = secrets.sorted { $0.count > $1.count }
        lock.unlock()
        return CaddyRuntimeLogRedactor.redact(line, secrets: values)
    }
}

enum CaddyRuntimeLogRedactor {
    static func redact(_ line: String, secrets: [String]) -> String {
        secrets.reduce(CaddyfileDocument.redactingCredentials(in: line)) {
            $0.replacingOccurrences(of: $1, with: "[REDACTED]")
        }
    }
}
