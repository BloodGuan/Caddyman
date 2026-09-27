import Foundation
import XCTest
@testable import Caddyman

final class CaddyAppLifecycleTests: XCTestCase {
    @MainActor
    func testEnabledCaddyStartsOnceWithAppAndStopsOnQuit() async throws {
        let fixture = try LifecycleFixture(startsWithApp: true)
        defer { fixture.cleanUp() }

        await fixture.model.applicationDidLaunch()
        await fixture.model.applicationDidLaunch()

        XCTAssertEqual(fixture.runtime.startCount, 1)
        XCTAssertTrue(fixture.model.sessionCaddyIsRunning)
        let stopped = await fixture.model.stopOwnedCaddyForTermination()
        XCTAssertTrue(stopped)
        XCTAssertEqual(fixture.runtime.stopCount, 1)
        XCTAssertFalse(fixture.model.managedCaddyIsRunning)
        XCTAssertEqual(fixture.agent.installCount, 0)
    }

    @MainActor
    func testManualStopDoesNotRestartDuringSameAppSession() async throws {
        let fixture = try LifecycleFixture(startsWithApp: true)
        defer { fixture.cleanUp() }

        await fixture.model.applicationDidLaunch()
        _ = await fixture.model.stopManagedCaddy()
        await fixture.model.applicationDidLaunch()

        XCTAssertEqual(fixture.runtime.startCount, 1)
        XCTAssertEqual(fixture.runtime.stopCount, 1)
        XCTAssertFalse(fixture.runtime.isRunning)
    }

    @MainActor
    func testLegacyIndependentServicePreventsSecondCaddyAndStopsOnQuit() async throws {
        let fixture = try LifecycleFixture(startsWithApp: true, oldServiceRunning: true)
        defer { fixture.cleanUp() }

        await fixture.model.applicationDidLaunch()

        XCTAssertEqual(fixture.runtime.startCount, 0)
        XCTAssertTrue(fixture.model.launchAgentSnapshot.isRunning)
        let stopped = await fixture.model.stopOwnedCaddyForTermination()
        XCTAssertTrue(stopped)
        XCTAssertEqual(fixture.agent.stopCount, 1)
        XCTAssertEqual(fixture.agent.installCount, 0)
    }

    @MainActor
    func testEnablingFollowAppStartsNowAndSavesOnlyAfterSuccess() async throws {
        let fixture = try LifecycleFixture(startsWithApp: false)
        defer { fixture.cleanUp() }
        await fixture.model.refresh()

        _ = await fixture.model.setStartsCaddyWithApp(true)

        XCTAssertTrue(fixture.model.startsCaddyWithApp)
        XCTAssertTrue(fixture.preference.enabled)
        XCTAssertTrue(fixture.runtime.isRunning)
        XCTAssertEqual(fixture.agent.installCount, 0)
    }

    @MainActor
    func testInvalidCaddyfileDoesNotSaveAutomaticStart() async throws {
        let fixture = try LifecycleFixture(startsWithApp: false, validCandidate: false)
        defer { fixture.cleanUp() }
        await fixture.model.refresh()

        _ = await fixture.model.setStartsCaddyWithApp(true)

        XCTAssertFalse(fixture.preference.enabled)
        XCTAssertFalse(fixture.model.startsCaddyWithApp)
        XCTAssertEqual(fixture.runtime.startCount, 0)
    }

    @MainActor
    func testAppLaunchWaitsForConcurrentRefreshBeforeStartingCaddy() async throws {
        let fixture = try LifecycleFixture(startsWithApp: true, inspectionDelay: true)
        defer { fixture.cleanUp() }
        let refreshing = Task { await fixture.model.refresh() }
        try await Task.sleep(for: .milliseconds(10))

        await fixture.model.applicationDidLaunch()
        await refreshing.value

        XCTAssertEqual(fixture.runtime.startCount, 1)
    }

    @MainActor
    func testFailedStopKeepsAppTerminationPending() async throws {
        let fixture = try LifecycleFixture(startsWithApp: true)
        defer { fixture.cleanUp() }
        await fixture.model.applicationDidLaunch()
        fixture.runtime.shouldFailStop = true

        let stopped = await fixture.model.stopOwnedCaddyForTermination()

        XCTAssertFalse(stopped)
        XCTAssertTrue(fixture.runtime.isRunning)
        fixture.runtime.shouldFailStop = false
        let retry = await fixture.model.stopOwnedCaddyForTermination()
        XCTAssertTrue(retry)
    }
}

@MainActor
private final class LifecycleFixture {
    let directory: URL
    let runtime = LifecycleRuntime()
    let agent: LifecycleAgent
    let preference: LifecyclePreference
    let model: CaddymanAppModel

    init(startsWithApp: Bool, oldServiceRunning: Bool = false,
         validCandidate: Bool = true, inspectionDelay: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("Caddyfile")
        try Data("# lifecycle fixture\n".utf8).write(to: configURL)
        agent = LifecycleAgent(configurationURL: configURL, running: oldServiceRunning)
        preference = LifecyclePreference(enabled: startsWithApp)
        model = CaddymanAppModel(
            pathStore: LifecycleBinaryPathStore(),
            caddyfilePathStore: LifecycleCaddyfilePathStore(path: configURL.path),
            caddyfileHashStore: LifecycleHashStore(),
            binaryLocator: LifecycleBinaryLocator(),
            binaryInspector: LifecycleBinaryInspector(delay: inspectionDelay),
            serviceChecker: LifecycleServiceChecker(),
            candidateValidator: LifecycleValidator(isValid: validCandidate),
            runtimeController: runtime,
            launchAgentController: agent,
            loginItem: LifecycleLoginItem(),
            appStartStore: preference)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor private final class LifecyclePreference: CaddyAppStartStoring {
    var enabled: Bool
    init(enabled: Bool) { self.enabled = enabled }
    func loadEnabled() -> Bool { enabled }
    func saveEnabled(_ enabled: Bool) { self.enabled = enabled }
}

@MainActor private struct LifecycleBinaryPathStore: CaddyBinaryPathStoring {
    func loadPath() -> String { "" }
    func savePath(_ path: String) {}
}

@MainActor private struct LifecycleCaddyfilePathStore: CaddyfilePathStoring {
    let path: String
    func loadPath() -> String { path }
    func savePath(_ path: String) {}
}

@MainActor private final class LifecycleHashStore: CaddyfileHashStoring {
    private var hash: String?
    func loadHash() -> String? { hash }
    func saveHash(_ hash: String?) { self.hash = hash }
}

private struct LifecycleBinaryLocator: CaddyBinaryLocating {
    func locate(explicitPath: String) throws -> URL { URL(fileURLWithPath: "/usr/bin/true") }
}

private struct LifecycleBinaryInspector: CaddyBinaryInspecting {
    let delay: Bool
    func inspect(binaryURL: URL) async throws -> CaddyInstallationInfo {
        if delay { try? await Task.sleep(for: .milliseconds(100)) }
        return CaddyInstallationInfo(binaryURL: binaryURL, version: "test", dnsPodStatus: .missing,
                              moduleCount: 0, checkedAt: Date())
    }
}

private struct LifecycleValidator: CaddyCandidateValidating {
    let isValid: Bool
    func validate(candidateData: Data, binaryURL: URL, workingDirectoryURL: URL,
                  environment: [String: String], sensitiveValues: [String]) async -> CaddyCandidateValidationResult {
        CaddyCandidateValidationResult(isValid: isValid, detail: isValid ? "valid" : "invalid")
    }
}

private actor LifecycleServiceChecker: CaddyServiceChecking {
    private var count = 0
    func check() async -> CaddyServiceObservation {
        count += 1
        return count < 3 ? .unavailable : .adminPortResponding(port: 2019)
    }
}

@MainActor private final class LifecycleRuntime: CaddyRuntimeControlling {
    private(set) var isRunning = false
    private(set) var configurationPath: String?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var shouldFailStop = false

    func start(binaryURL: URL, configurationURL: URL, environment: [String: String], secrets: [String],
               outputHandler: @escaping @MainActor @Sendable (String) -> Void) throws {
        startCount += 1
        isRunning = true
        configurationPath = configurationURL.standardizedFileURL.path
    }
    func stop() async throws {
        if shouldFailStop { throw CaddyRuntimeError.stopFailed }
        stopCount += 1
        isRunning = false
        configurationPath = nil
    }
    func reload(binaryURL: URL, configurationURL: URL, environment: [String: String], secrets: [String]) async throws {}
}

@MainActor private final class LifecycleAgent: CaddyLaunchAgentControlling {
    private(set) var installCount = 0
    private(set) var stopCount = 0
    private var snapshot: CaddyLaunchAgentSnapshot

    init(configurationURL: URL, running: Bool) {
        snapshot = running
            ? CaddyLaunchAgentSnapshot(isInstalled: true, isRunning: true, isDisabled: false,
                pid: 123, configuration: CaddyLaunchAgentConfiguration(
                    launcherURL: URL(fileURLWithPath: "/Applications/Caddyman.app/Contents/MacOS/Caddyman"),
                    binaryURL: URL(fileURLWithPath: "/usr/bin/true"), caddyfileURL: configurationURL),
                issue: nil, isForeign: false)
            : .notInstalled
    }
    func inspect() async -> CaddyLaunchAgentSnapshot { snapshot }
    func installAndStart(_ configuration: CaddyLaunchAgentConfiguration) async throws { installCount += 1 }
    func uninstall() async throws { snapshot = .notInstalled }
    func start() async throws {}
    func stop() async throws {
        stopCount += 1
        snapshot = CaddyLaunchAgentSnapshot(isInstalled: true, isRunning: false, isDisabled: true,
            pid: nil, configuration: snapshot.configuration, issue: nil, isForeign: false)
    }
    func restart() async throws {}
    func reload(configuration: CaddyLaunchAgentConfiguration, environment: [String: String], secrets: [String]) async throws {}
}

@MainActor private final class LifecycleLoginItem: CaddymanLoginManaging {
    func status() -> CaddymanLoginStatus { .disabled }
    func setEnabled(_ enabled: Bool) throws {}
}
