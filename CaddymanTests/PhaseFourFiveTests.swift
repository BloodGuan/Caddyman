import Foundation
import XCTest
@testable import Caddyman

final class PhaseFourFiveTests: XCTestCase {
    @MainActor
    func testReloadFailureRestoresPreviousCaddyfileAndAttemptsRollbackReload() async throws {
        let original = Data("# User-owned base\n".utf8)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaddymanRollback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("Caddyfile")
        try original.write(to: configURL)

        let runtime = FailingOnceRuntimeController(configurationPath: configURL.path)
        let model = CaddymanAppModel(
            caddyfilePathStore: TestCaddyfilePathStore(),
            caddyfileHashStore: TestCaddyfileHashStore(),
            binaryLocator: FixtureBinaryLocator(),
            serviceChecker: AlwaysRespondingCaddyServiceChecker(),
            candidateValidator: AlwaysValidCandidateValidator(),
            runtimeController: runtime
        )
        model.setSelectedCaddyfilePath(configURL.path)
        let site = ReverseProxySite(hostname: "rollback.example.com", upstream: "127.0.0.1:8000")
        let preview = try model.makeSiteChangePreview(sites: [site])

        let result = await model.applySiteChangePreview(preview)

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(runtime.reloadCount, 2, "The failed candidate reload should be followed by an old-config reload.")
        XCTAssertEqual(try Data(contentsOf: configURL), original)
        XCTAssertNotNil(result.backupURL)
    }

    @MainActor
    func testValidCandidateReloadsOwnedProcessAfterBackupAndReadback() async throws {
        let original = Data("# User-owned base\n".utf8)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaddymanApply-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("Caddyfile")
        try original.write(to: configURL)

        let runtime = FailingOnceRuntimeController(configurationPath: configURL.path, failFirstReload: false)
        let model = CaddymanAppModel(
            caddyfilePathStore: TestCaddyfilePathStore(),
            caddyfileHashStore: TestCaddyfileHashStore(),
            binaryLocator: FixtureBinaryLocator(),
            serviceChecker: AlwaysRespondingCaddyServiceChecker(),
            candidateValidator: AlwaysValidCandidateValidator(),
            runtimeController: runtime
        )
        model.setSelectedCaddyfilePath(configURL.path)
        let site = ReverseProxySite(hostname: "valid.example.com", upstream: "127.0.0.1:8000")
        let preview = try model.makeSiteChangePreview(sites: [site])

        let result = await model.applySiteChangePreview(preview)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(runtime.reloadCount, 1)
        XCTAssertEqual(try CaddyfileSiteEditor.readManagedSites(from: CaddyfileDocument.read(from: configURL)), [site])
        XCTAssertNotNil(result.backupURL)
    }

    @MainActor
    func testInvalidCandidateDoesNotWriteOrCreateBackup() async throws {
        let original = Data("# User-owned base\n".utf8)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaddymanInvalid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("Caddyfile")
        try original.write(to: configURL)

        let model = CaddymanAppModel(
            caddyfilePathStore: TestCaddyfilePathStore(),
            caddyfileHashStore: TestCaddyfileHashStore(),
            binaryLocator: FixtureBinaryLocator(),
            candidateValidator: AlwaysInvalidCandidateValidator()
        )
        model.setSelectedCaddyfilePath(configURL.path)
        let preview = try model.makeSiteChangePreview(sites: [ReverseProxySite(hostname: "invalid.example.com")])

        let result = await model.applySiteChangePreview(preview)

        XCTAssertFalse(result.succeeded)
        XCTAssertNil(result.backupURL)
        XCTAssertEqual(try Data(contentsOf: configURL), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["Caddyfile"])
    }

    @MainActor
    func testKeychainActionsNeverReturnTheCredentialValue() {
        let store = MemoryCredentialStore()
        let model = CaddymanAppModel(
            caddyfilePathStore: TestCaddyfilePathStore(),
            caddyfileHashStore: TestCaddyfileHashStore(),
            credentialStore: store
        )
        let secret = "12345,secure_token+value="

        let saved = model.saveDNSPodTokenToKeychain(secret)
        let tested = model.testDNSPodKeychainRead()

        XCTAssertFalse(saved.contains(secret))
        XCTAssertFalse(tested.contains(secret))
        XCTAssertTrue(store.hasToken)
        XCTAssertFalse(model.deleteDNSPodTokenFromKeychain().contains(secret))
        XCTAssertFalse(store.hasToken)
    }

    @MainActor
    func testRuntimeCertificateFeedbackRedactsSecretsBeforeDisplay() {
        let model = CaddymanAppModel(
            caddyfilePathStore: TestCaddyfilePathStore(),
            caddyfileHashStore: TestCaddyfileHashStore()
        )
        let secret = "12345,secure_token+value="

        let safeLine = CaddyRuntimeLogRedactor.redact(
            "tls.obtain: certificate error: token \(secret)", secrets: [secret]
        )
        model.consumeManagedCaddyOutput(safeLine)

        XCTAssertEqual(model.certificateIssuanceStatus, L10n.format("Caddy reported a certificate error: %@", safeLine))
        XCTAssertFalse(model.recentManagedCaddyLogs.joined().contains(secret))
        XCTAssertFalse(model.latestCertificateIssuanceLog?.contains(secret) ?? false)
    }

    func testRuntimeLogRedactorCoversTokensAddedDuringReload() {
        let first = "100,first_secret"
        let rotated = "100,rotated_secret"
        let redactor = RuntimeSecretRedactor(secrets: [first])

        redactor.add(secrets: [rotated])

        let output = redactor.redact("old=\(first) new=\(rotated)")
        XCTAssertFalse(output.contains(first))
        XCTAssertFalse(output.contains(rotated))
    }

    @MainActor
    func testManagedStartRunsOnceWhileBusyAndStopTargetsOwnedRuntime() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaddymanRuntime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("Caddyfile")
        try Data("# fixture\n".utf8).write(to: configURL)

        let runtime = CountingRuntimeController()
        let model = CaddymanAppModel(
            caddyfilePathStore: TestCaddyfilePathStore(),
            caddyfileHashStore: TestCaddyfileHashStore(),
            binaryLocator: FixtureBinaryLocator(),
            binaryInspector: StubBinaryInspector(),
            serviceChecker: StartSequenceServiceChecker(),
            candidateValidator: DelayedValidCandidateValidator(),
            runtimeController: runtime
        )
        model.setSelectedCaddyfilePath(configURL.path)

        let firstStart = Task { await model.startManagedCaddy() }
        try await Task.sleep(for: .milliseconds(20))
        _ = await model.startManagedCaddy()
        _ = await firstStart.value

        XCTAssertEqual(runtime.startCount, 1)
        XCTAssertTrue(runtime.isRunning)
        _ = await model.stopManagedCaddy()
        XCTAssertEqual(runtime.stopCount, 1)
        XCTAssertFalse(runtime.isRunning)
    }

}

private struct FixtureBinaryLocator: CaddyBinaryLocating {
    func locate(explicitPath: String) throws -> URL { URL(fileURLWithPath: "/usr/bin/true") }
}

private struct AlwaysValidCandidateValidator: CaddyCandidateValidating {
    func validate(
        candidateData: Data,
        binaryURL: URL,
        workingDirectoryURL: URL,
        environment: [String: String],
        sensitiveValues: [String]
    ) async -> CaddyCandidateValidationResult {
        CaddyCandidateValidationResult(isValid: true, detail: "valid")
    }
}

private struct AlwaysInvalidCandidateValidator: CaddyCandidateValidating {
    func validate(
        candidateData: Data,
        binaryURL: URL,
        workingDirectoryURL: URL,
        environment: [String: String],
        sensitiveValues: [String]
    ) async -> CaddyCandidateValidationResult {
        CaddyCandidateValidationResult(isValid: false, detail: "fixture rejection")
    }
}

private struct DelayedValidCandidateValidator: CaddyCandidateValidating {
    func validate(
        candidateData: Data,
        binaryURL: URL,
        workingDirectoryURL: URL,
        environment: [String: String],
        sensitiveValues: [String]
    ) async -> CaddyCandidateValidationResult {
        try? await Task.sleep(for: .milliseconds(80))
        return CaddyCandidateValidationResult(isValid: true, detail: "valid")
    }
}

private struct StubBinaryInspector: CaddyBinaryInspecting {
    func inspect(binaryURL: URL) async throws -> CaddyInstallationInfo {
        CaddyInstallationInfo(binaryURL: binaryURL, version: "test", dnsPodStatus: .missing,
                              moduleCount: 0, checkedAt: Date())
    }
}

private actor StartSequenceServiceChecker: CaddyServiceChecking {
    private var checks = 0

    func check() async -> CaddyServiceObservation {
        checks += 1
        return checks == 1 ? .unavailable : .adminPortResponding(port: 2019)
    }
}

@MainActor
private final class CountingRuntimeController: CaddyRuntimeControlling {
    private(set) var isRunning = false
    private(set) var configurationPath: String?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(
        binaryURL: URL,
        configurationURL: URL,
        environment: [String: String],
        secrets: [String],
        outputHandler: @escaping @MainActor @Sendable (String) -> Void
    ) throws {
        startCount += 1
        isRunning = true
        configurationPath = configurationURL.standardizedFileURL.path
    }

    func stop() async throws {
        stopCount += 1
        isRunning = false
        configurationPath = nil
    }

    func reload(binaryURL: URL, configurationURL: URL, environment: [String: String], secrets: [String]) async throws {}
}

@MainActor
private final class FailingOnceRuntimeController: CaddyRuntimeControlling {
    var isRunning = true
    let configurationPath: String?
    private(set) var reloadCount = 0
    private let failFirstReload: Bool

    init(configurationPath: String, failFirstReload: Bool = true) {
        self.configurationPath = configurationPath
        self.failFirstReload = failFirstReload
    }

    func start(
        binaryURL: URL,
        configurationURL: URL,
        environment: [String: String],
        secrets: [String],
        outputHandler: @escaping @MainActor @Sendable (String) -> Void
    ) throws {}
    func stop() async throws { isRunning = false }

    func reload(binaryURL: URL, configurationURL: URL, environment: [String: String], secrets: [String]) async throws {
        reloadCount += 1
        if failFirstReload && reloadCount == 1 { throw CaddyRuntimeError.reloadFailed("fixture rejection") }
    }
}

private final class MemoryCredentialStore: DNSPodCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    var hasToken: Bool {
        lock.lock()
        defer { lock.unlock() }
        return token != nil
    }

    func readToken() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    func saveToken(_ token: String) throws {
        guard ReverseProxySiteValidator.isValidDNSPodToken(token) else {
            throw DNSPodCredentialStoreError.invalidToken
        }
        lock.lock()
        defer { lock.unlock() }
        self.token = token
    }

    func deleteToken() throws {
        lock.lock()
        defer { lock.unlock() }
        token = nil
    }
}

private struct AlwaysRespondingCaddyServiceChecker: CaddyServiceChecking {
    func check() async -> CaddyServiceObservation { .adminPortResponding(port: 2019) }
}

@MainActor
private final class TestCaddyfilePathStore: CaddyfilePathStoring {
    private var path = ""
    func loadPath() -> String { path }
    func savePath(_ path: String) { self.path = path }
}

@MainActor
private final class TestCaddyfileHashStore: CaddyfileHashStoring {
    private var hash: String?
    func loadHash() -> String? { hash }
    func saveHash(_ hash: String?) { self.hash = hash }
}
