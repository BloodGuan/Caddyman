import Darwin
import Foundation

struct ProcessRequest: Sendable {
    let executableURL: URL
    let arguments: [String]
    let timeout: TimeInterval
    let outputLimitBytes: Int
    let standardInput: Data?
    let workingDirectoryURL: URL?
    let environment: [String: String]?
    let environmentVariablesToRemove: [String]

    init(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval = 5,
        outputLimitBytes: Int = 64 * 1024,
        standardInput: Data? = nil,
        workingDirectoryURL: URL? = nil,
        environment: [String: String]? = nil,
        environmentVariablesToRemove: [String] = []
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.timeout = timeout
        self.outputLimitBytes = max(0, outputLimitBytes)
        self.standardInput = standardInput
        self.workingDirectoryURL = workingDirectoryURL
        self.environment = environment
        self.environmentVariablesToRemove = environmentVariablesToRemove
    }
}

struct ProcessResult: Equatable, Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let stdoutWasTruncated: Bool
    let stderrWasTruncated: Bool
}

enum ProcessRunnerError: Error, LocalizedError {
    case launchFailed
    case timedOut

    var errorDescription: String? {
        switch self {
        case .launchFailed:
            L10n.text("The executable could not be started. Check that the selected file is a valid executable.")
        case .timedOut:
            L10n.text("The Caddy command did not finish before the timeout.")
        }
    }
}

protocol ProcessRunning: Sendable {
    func run(_ request: ProcessRequest) async throws -> ProcessResult
}

struct FoundationProcessRunner: ProcessRunning {
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        let task = Task.detached(priority: .utility) {
            try Self.runSynchronously(request)
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func runSynchronously(_ request: ProcessRequest) throws -> ProcessResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = request.standardInput.map { _ in Pipe() }
        let stdoutCapture = LimitedOutputCapture(limit: request.outputLimitBytes)
        let stderrCapture = LimitedOutputCapture(limit: request.outputLimitBytes)

        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.standardInput = stdinPipe ?? FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.currentDirectoryURL = request.workingDirectoryURL
        if request.environment != nil || !request.environmentVariablesToRemove.isEmpty {
            var childEnvironment = ProcessInfo.processInfo.environment
            request.environmentVariablesToRemove.forEach { childEnvironment.removeValue(forKey: $0) }
            process.environment = childEnvironment.merging(request.environment ?? [:]) { _, override in override }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stdoutCapture.append(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stderrCapture.append(data)
            }
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw ProcessRunnerError.launchFailed
        }

        if let stdinPipe, let standardInput = request.standardInput {
            try? stdinPipe.fileHandleForReading.close()
            let inputHandle = stdinPipe.fileHandleForWriting
            DispatchQueue.global(qos: .utility).async {
                do {
                    try inputHandle.write(contentsOf: standardInput)
                } catch {
                    // The child may exit early; in that case, the remaining input is discarded.
                }
                try? inputHandle.close()
            }
        }

        let deadline = Date().addingTimeInterval(max(0.01, request.timeout))
        while process.isRunning {
            if Task.isCancelled {
                terminate(process)
                closeAndDrain(stdoutPipe.fileHandleForReading, into: stdoutCapture)
                closeAndDrain(stderrPipe.fileHandleForReading, into: stderrCapture)
                throw CancellationError()
            }

            if Date() >= deadline {
                terminate(process)
                closeAndDrain(stdoutPipe.fileHandleForReading, into: stdoutCapture)
                closeAndDrain(stderrPipe.fileHandleForReading, into: stderrCapture)
                throw ProcessRunnerError.timedOut
            }

            Thread.sleep(forTimeInterval: 0.025)
        }

        closeAndDrain(stdoutPipe.fileHandleForReading, into: stdoutCapture)
        closeAndDrain(stderrPipe.fileHandleForReading, into: stderrCapture)

        let stdout = stdoutCapture.snapshot()
        let stderr = stderrCapture.snapshot()
        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdout.data, as: UTF8.self),
            stderr: String(decoding: stderr.data, as: UTF8.self),
            stdoutWasTruncated: stdout.wasTruncated,
            stderrWasTruncated: stderr.wasTruncated
        )
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()

        let graceDeadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < graceDeadline {
            Thread.sleep(forTimeInterval: 0.025)
        }

        if process.isRunning {
            _ = Darwin.kill(pid_t(process.processIdentifier), SIGKILL)
            process.waitUntilExit()
        }
    }

    private static func closeAndDrain(_ handle: FileHandle, into capture: LimitedOutputCapture) {
        handle.readabilityHandler = nil
        let remaining = handle.readDataToEndOfFile()
        if !remaining.isEmpty {
            capture.append(remaining)
        }
    }
}

private final class LimitedOutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var wasTruncated = false

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ incoming: Data) {
        lock.lock()
        defer { lock.unlock() }

        let remaining = max(0, limit - data.count)
        if remaining > 0 {
            data.append(incoming.prefix(remaining))
        }
        if incoming.count > remaining {
            wasTruncated = true
        }
    }

    func snapshot() -> (data: Data, wasTruncated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (data, wasTruncated)
    }
}
