import Foundation
import XCTest
@testable import Caddyman

final class PhaseSixTests: XCTestCase {
    func testPlistKeepsPathsLiteralAndContainsNoCredential() throws {
        let configuration = CaddyLaunchAgentConfiguration(
            launcherURL: URL(fileURLWithPath: "/Applications/Caddy Manager.app/Contents/MacOS/Caddyman"),
            binaryURL: URL(fileURLWithPath: "/Users/test/Caddy Tools/caddy"),
            caddyfileURL: URL(fileURLWithPath: "/Users/test/My Sites/Caddyfile")
        )
        let data = try CaddyLaunchAgentPlist.render(configuration)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("DNSPOD_TOKEN"))
        XCTAssertFalse(text.contains("APP_TOKEN"))
        XCTAssertEqual(try CaddyLaunchAgentPlist.readOwnedConfiguration(from: data), configuration)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [
            configuration.launcherURL.path, "--caddyman-launch-caddy", "--binary",
            configuration.binaryURL.path, "--config", configuration.caddyfileURL.path
        ])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["KeepAlive"] as? [String: Bool], ["SuccessfulExit": false])
    }

    func testForeignPlistIsRejected() throws {
        let data = try CaddyLaunchAgentPlist.render(CaddyLaunchAgentConfiguration(
            launcherURL: URL(fileURLWithPath: "/Applications/Caddyman.app/Contents/MacOS/Caddyman"),
            binaryURL: URL(fileURLWithPath: "/usr/local/bin/caddy"),
            caddyfileURL: URL(fileURLWithPath: "/tmp/Caddyfile")
        ))
        var plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        plist["EnvironmentVariables"] = ["DNSPOD_TOKEN": "secret"]
        let foreign = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        XCTAssertThrowsError(try CaddyLaunchAgentPlist.readOwnedConfiguration(from: foreign))
    }

    @MainActor
    func testManualStopDisablesBeforeBootoutAndStartReenables() async throws {
        let runner = SimulatedLaunchctlRunner()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let agentURL = folder.appendingPathComponent("com.blood.caddyman.caddy.plist")
        let caddyfileURL = folder.appendingPathComponent("Caddy file")
        let certificateURL = folder.appendingPathComponent("certificates")
        try Data("example.test { respond ok }".utf8).write(to: caddyfileURL)
        try FileManager.default.createDirectory(at: certificateURL, withIntermediateDirectories: true)
        let configuration = CaddyLaunchAgentConfiguration(
            launcherURL: URL(fileURLWithPath: "/Applications/Caddyman.app/Contents/MacOS/Caddyman"),
            binaryURL: URL(fileURLWithPath: "/usr/local/bin/caddy"),
            caddyfileURL: caddyfileURL
        )
        let controller = CaddyLaunchAgentController(runner: runner, agentURL: agentURL, uid: 501)
        try await controller.installAndStart(configuration)
        let started = await controller.inspect()
        XCTAssertTrue(started.isRunning)
        try await controller.stop()
        let stopped = await controller.inspect()
        XCTAssertTrue(stopped.isInstalled)
        XCTAssertFalse(stopped.isRunning)
        XCTAssertTrue(stopped.isDisabled)
        await runner.simulateLogin()
        let afterStoppedLogin = await controller.inspect()
        XCTAssertFalse(afterStoppedLogin.isRunning)
        let commands = await runner.commands
        let disableIndex = try XCTUnwrap(commands.firstIndex(of: ["disable", "gui/501/com.blood.caddyman.caddy"]))
        let bootoutIndex = try XCTUnwrap(commands.firstIndex(of: ["bootout", "gui/501", agentURL.path]))
        XCTAssertLessThan(disableIndex, bootoutIndex)
        try await controller.start()
        let restarted = await controller.inspect()
        XCTAssertTrue(restarted.isRunning)
        await runner.simulateLogout()
        await runner.simulateLogin()
        let afterNextLogin = await controller.inspect()
        XCTAssertTrue(afterNextLogin.isRunning)
        try await controller.uninstall()
        XCTAssertFalse(FileManager.default.fileExists(atPath: agentURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: caddyfileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: certificateURL.path))
        let uninstalled = await controller.inspect()
        XCTAssertFalse(uninstalled.isInstalled)
    }

    @MainActor
    func testFailedUpgradeRestoresPreviousServiceDefinition() async throws {
        let runner = SimulatedLaunchctlRunner()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let agentURL = folder.appendingPathComponent("com.blood.caddyman.caddy.plist")
        let first = CaddyLaunchAgentConfiguration(
            launcherURL: URL(fileURLWithPath: "/Applications/Caddyman.app/Contents/MacOS/Caddyman"),
            binaryURL: URL(fileURLWithPath: "/usr/local/bin/caddy"),
            caddyfileURL: folder.appendingPathComponent("Caddyfile"))
        let second = CaddyLaunchAgentConfiguration(
            launcherURL: first.launcherURL, binaryURL: first.binaryURL,
            caddyfileURL: folder.appendingPathComponent("Replacement Caddyfile"))
        let controller = CaddyLaunchAgentController(runner: runner, agentURL: agentURL, uid: 501)
        try await controller.installAndStart(first)
        await runner.failNextBootstrap()
        do {
            try await controller.installAndStart(second)
            XCTFail("Expected the simulated bootstrap failure")
        } catch { /* The previous definition is restored below. */ }
        let restored = try CaddyLaunchAgentPlist.readOwnedConfiguration(from: Data(contentsOf: agentURL))
        XCTAssertEqual(restored, first)
        let snapshot = await controller.inspect()
        XCTAssertTrue(snapshot.isRunning)
    }

    @MainActor
    func testLoadedForeignJobWithSameLabelIsNotStopped() async throws {
        let runner = SimulatedLaunchctlRunner()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let agentURL = folder.appendingPathComponent("com.blood.caddyman.caddy.plist")
        let controller = CaddyLaunchAgentController(runner: runner, agentURL: agentURL, uid: 501)
        try await controller.installAndStart(CaddyLaunchAgentConfiguration(
            launcherURL: URL(fileURLWithPath: "/Applications/Caddyman.app/Contents/MacOS/Caddyman"),
            binaryURL: URL(fileURLWithPath: "/usr/local/bin/caddy"),
            caddyfileURL: folder.appendingPathComponent("Caddyfile")))
        await runner.simulateForeignJob()
        let snapshot = await controller.inspect()
        XCTAssertTrue(snapshot.isForeign)
        let countBefore = (await runner.commands).count
        do {
            try await controller.stop()
            XCTFail("A foreign job must not be stopped")
        } catch CaddyLaunchAgentError.foreignAgent { /* Expected. */ }
        let laterCommands = Array((await runner.commands).dropFirst(countBefore))
        XCTAssertFalse(laterCommands.contains { $0.first == "bootout" || $0.first == "disable" })
    }

    func testLauncherRejectsMalformedArguments() {
        XCTAssertNil(CaddyLauncher.configuration(arguments: ["--caddyman-launch-caddy", "--binary", "relative", "--config", "/tmp/Caddyfile"]))
        XCTAssertNil(CaddyLauncher.configuration(arguments: ["--caddyman-launch-caddy", "--binary", "/bin/caddy", "--config", "/tmp/Caddyfile", "secret"]))
    }
}

private actor SimulatedLaunchctlRunner: ProcessRunning {
    private(set) var commands: [[String]] = []
    private var loaded = false
    private var disabled = false
    private var shouldFailBootstrap = false
    private var registeredPath: String?
    private var registeredProgram: String?

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        let args = request.arguments
        commands.append(args)
        let result: (Int32, String)
        switch args.first {
        case "print":
            result = loaded
                ? (0, "path = \(registeredPath ?? "")\nprogram = \(registeredProgram ?? "")\npid = 123\nlast exit code = 0\n")
                : (113, "")
        case "print-disabled": result = (0, "\"com.blood.caddyman.caddy\" => \(disabled ? "disabled" : "enabled")")
        case "enable": disabled = false; result = (0, "")
        case "disable": disabled = true; result = (0, "")
        case "bootstrap":
            if shouldFailBootstrap {
                shouldFailBootstrap = false
                result = (5, "simulated failure")
            } else {
                loaded = true
                registeredPath = args[2]
                registeredProgram = try? CaddyLaunchAgentPlist.readOwnedConfiguration(
                    from: Data(contentsOf: URL(fileURLWithPath: args[2]))).launcherURL.path
                result = (0, "")
            }
        case "bootout": loaded = false; result = (0, "")
        case "kickstart": loaded = true; result = (0, "")
        default: result = (1, "unexpected command")
        }
        return ProcessResult(exitCode: result.0, stdout: result.1, stderr: "",
                             stdoutWasTruncated: false, stderrWasTruncated: false)
    }

    func simulateLogout() { loaded = false }
    func simulateLogin() { if !disabled { loaded = true } }
    func failNextBootstrap() { shouldFailBootstrap = true }
    func simulateForeignJob() {
        loaded = true
        registeredPath = "/tmp/foreign.plist"
        registeredProgram = "/tmp/foreign"
    }
}
