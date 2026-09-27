import Foundation
import OSLog
import Observation

enum CaddymanSettingsTab: Hashable {
    case overview
    case sites
    case caddy
    case startup
    case dnsPod
    case about
}

enum CaddymanMenuBarStatus: Equatable {
    case running
    case ready
    case error
}

@MainActor
protocol CaddyBinaryPathStoring {
    func loadPath() -> String
    func savePath(_ path: String)
}

@MainActor
struct UserDefaultsCaddyBinaryPathStore: CaddyBinaryPathStoring {
    static let key = "caddy.binaryPath"

    func loadPath() -> String {
        UserDefaults.standard.string(forKey: Self.key) ?? ""
    }

    func savePath(_ path: String) {
        if path.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.key)
        } else {
            UserDefaults.standard.set(path, forKey: Self.key)
        }
    }
}

@MainActor
protocol CaddyfilePathStoring {
    func loadPath() -> String
    func savePath(_ path: String)
}

@MainActor
struct UserDefaultsCaddyfilePathStore: CaddyfilePathStoring {
    static let key = "caddy.caddyfilePath"

    func loadPath() -> String {
        UserDefaults.standard.string(forKey: Self.key) ?? ""
    }

    func savePath(_ path: String) {
        if path.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.key)
        } else {
            UserDefaults.standard.set(path, forKey: Self.key)
        }
    }
}

@MainActor
protocol CaddyfileHashStoring {
    func loadHash() -> String?
    func saveHash(_ hash: String?)
}

@MainActor
struct UserDefaultsCaddyfileHashStore: CaddyfileHashStoring {
    static let key = "caddy.caddyfileHash"

    func loadHash() -> String? {
        UserDefaults.standard.string(forKey: Self.key)
    }

    func saveHash(_ hash: String?) {
        if let hash {
            UserDefaults.standard.set(hash, forKey: Self.key)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.key)
        }
    }
}

@MainActor
protocol CaddyAppStartStoring {
    func loadEnabled() -> Bool
    func saveEnabled(_ enabled: Bool)
}

@MainActor
struct UserDefaultsCaddyAppStartStore: CaddyAppStartStoring {
    static let key = "caddy.startWithApp"

    func loadEnabled() -> Bool { UserDefaults.standard.bool(forKey: Self.key) }
    func saveEnabled(_ enabled: Bool) { UserDefaults.standard.set(enabled, forKey: Self.key) }
}

@MainActor
@Observable
final class CaddymanAppModel {
    private let pathStore: any CaddyBinaryPathStoring
    private let caddyfilePathStore: any CaddyfilePathStoring
    private let caddyfileHashStore: any CaddyfileHashStoring
    private let binaryLocator: any CaddyBinaryLocating
    private let binaryInspector: any CaddyBinaryInspecting
    private let serviceChecker: any CaddyServiceChecking
    private let candidateValidator: any CaddyCandidateValidating
    private let caddyfileWriter: any CaddyfileWriting
    private let credentialStore: any DNSPodCredentialStoring
    private let runtimeController: any CaddyRuntimeControlling
    private let launchAgentController: any CaddyLaunchAgentControlling
    private let loginItem: any CaddymanLoginManaging
    private let appStartStore: any CaddyAppStartStoring

    var selectedBinaryPath: String {
        didSet { pathStore.savePath(selectedBinaryPath) }
    }

    var selectedCaddyfilePath: String {
        didSet { caddyfilePathStore.savePath(selectedCaddyfilePath) }
    }

    var selectedSettingsTab: CaddymanSettingsTab = .overview
    private(set) var startsCaddyWithApp: Bool

    var managedSiteDefinitions: [ReverseProxySite] {
        guard case .loaded(let document) = caddyfileReadState else { return [] }
        return (try? CaddyfileSiteEditor.readManagedSites(from: document)) ?? []
    }

    var totalCaddyfileSiteCount: Int {
        guard case .loaded(let document) = caddyfileReadState else { return 0 }
        return document.siteBlocks.count + document.importedCaddyfiles.reduce(0) { $0 + $1.siteBlocks.count }
    }

    var managedSiteReadError: String? {
        guard case .loaded(let document) = caddyfileReadState else { return nil }
        do {
            _ = try CaddyfileSiteEditor.readManagedSites(from: document)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private(set) var inspectionState: CaddyInspectionState = .notChecked
    private(set) var serviceStatus: CaddyServiceObservation = .notChecked
    private(set) var caddyfileReadState: CaddyfileReadState = .notSelected
    private(set) var caddyfileExternalChangeDetected = false
    private(set) var previousCaddyfileDocument: CaddyfileDocument?
    private(set) var isRefreshing = false
    private(set) var isPerformingRuntimeAction = false
    private(set) var lastRuntimeActionFailed = false
    private(set) var lastRefreshDate: Date?
    private(set) var runtimeActionMessage: String?
    private(set) var certificateIssuanceStatus: String?
    private(set) var latestCertificateIssuanceLog: String?
    private(set) var recentManagedCaddyLogs: [String] = []
    private(set) var launchAgentSnapshot: CaddyLaunchAgentSnapshot = .notInstalled
    private(set) var loginStatus: CaddymanLoginStatus = .disabled
    private var initialCaddyfileHash: String?
    private var certificateMonitorTask: Task<Void, Never>?
    private var certificateMonitorID = UUID()
    private var didRunLaunchAction = false
    private var isTerminating = false

    private static let runtimeLogger = Logger(subsystem: "com.blood.caddyman", category: "Caddy runtime")

    init(
        pathStore: (any CaddyBinaryPathStoring)? = nil,
        caddyfilePathStore: (any CaddyfilePathStoring)? = nil,
        caddyfileHashStore: (any CaddyfileHashStoring)? = nil,
        binaryLocator: any CaddyBinaryLocating = CaddyBinaryLocator(),
        binaryInspector: any CaddyBinaryInspecting = CaddyBinaryInspector(),
        serviceChecker: any CaddyServiceChecking = LoopbackCaddyServiceChecker(),
        candidateValidator: any CaddyCandidateValidating = CaddyCandidateValidator(),
        caddyfileWriter: any CaddyfileWriting = CaddyfileAtomicWriter(),
        credentialStore: any DNSPodCredentialStoring = DNSPodKeychainCredentialStore(),
        runtimeController: (any CaddyRuntimeControlling)? = nil,
        launchAgentController: (any CaddyLaunchAgentControlling)? = nil,
        loginItem: (any CaddymanLoginManaging)? = nil,
        appStartStore: (any CaddyAppStartStoring)? = nil
    ) {
        let resolvedPathStore = pathStore ?? UserDefaultsCaddyBinaryPathStore()
        let resolvedCaddyfilePathStore = caddyfilePathStore ?? UserDefaultsCaddyfilePathStore()
        let resolvedCaddyfileHashStore = caddyfileHashStore ?? UserDefaultsCaddyfileHashStore()
        let resolvedAppStartStore = appStartStore ?? UserDefaultsCaddyAppStartStore()
        self.pathStore = resolvedPathStore
        self.caddyfilePathStore = resolvedCaddyfilePathStore
        self.caddyfileHashStore = resolvedCaddyfileHashStore
        self.appStartStore = resolvedAppStartStore
        self.binaryLocator = binaryLocator
        self.binaryInspector = binaryInspector
        self.serviceChecker = serviceChecker
        self.candidateValidator = candidateValidator
        self.caddyfileWriter = caddyfileWriter
        self.credentialStore = credentialStore
        self.runtimeController = runtimeController ?? CaddySessionRuntimeController()
        self.launchAgentController = launchAgentController ?? CaddyLaunchAgentController()
        self.loginItem = loginItem ?? CaddymanLoginItem()
        self.selectedBinaryPath = resolvedPathStore.loadPath()
        self.selectedCaddyfilePath = resolvedCaddyfilePathStore.loadPath()
        self.initialCaddyfileHash = resolvedCaddyfileHashStore.loadHash()
        self.startsCaddyWithApp = resolvedAppStartStore.loadEnabled()
    }

    var menuBarStatus: CaddymanMenuBarStatus {
        guard case .ready = inspectionState,
              case .loaded = caddyfileReadState,
              managedSiteReadError == nil,
              !caddyfileExternalChangeDetected,
              !lastRuntimeActionFailed,
              launchAgentSnapshot.issue == nil,
              !launchAgentSnapshot.isForeign else {
            return .error
        }

        if managedCaddyIsRunning {
            if case .unavailable = serviceStatus { return .error }
            return .running
        }
        if case .adminPortResponding = serviceStatus { return .error }
        return .ready
    }

    var menuBarAccessibilityLabel: String {
        switch menuBarStatus {
        case .running:
            L10n.text("Caddyman: managed Caddy is running")
        case .ready:
            L10n.text("Caddyman: configuration is ready; Caddy is stopped")
        case .error:
            L10n.text("Caddyman: needs attention")
        }
    }

    var lastRefreshDescription: String {
        guard let lastRefreshDate else { return L10n.text("Not checked yet") }
        return L10n.format("Last checked %@", lastRefreshDate.formatted(date: .abbreviated, time: .shortened))
    }

    func setSelectedBinaryPath(_ path: String) async {
        selectedBinaryPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        lastRuntimeActionFailed = false
        await refresh()
    }

    func useAutomaticDiscovery() async {
        selectedBinaryPath = ""
        lastRuntimeActionFailed = false
        await refresh()
    }

    func setSelectedCaddyfilePath(_ path: String) {
        let newPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if selectedCaddyfilePath != newPath {
            selectedCaddyfilePath = newPath
            lastRuntimeActionFailed = false
            initialCaddyfileHash = nil
            caddyfileHashStore.saveHash(nil)
            caddyfileExternalChangeDetected = false
            previousCaddyfileDocument = nil
            caddyfileReadState = .notSelected
        }
        loadSelectedCaddyfile()
    }

    func clearSelectedCaddyfile() {
        selectedCaddyfilePath = ""
        lastRuntimeActionFailed = false
        initialCaddyfileHash = nil
        caddyfileHashStore.saveHash(nil)
        caddyfileExternalChangeDetected = false
        previousCaddyfileDocument = nil
        caddyfileReadState = .notSelected
    }

    func acceptExternalCaddyfileChanges() {
        lastRuntimeActionFailed = false
        resetCaddyfileChangeBaseline()
        loadSelectedCaddyfile()
    }

    func validateCaddyfileCandidate(_ data: Data, workingDirectoryURL: URL) async -> CaddyCandidateValidationResult {
        do {
            let binaryURL = try binaryLocator.locate(explicitPath: selectedBinaryPath)
            let credentials = try credentialEnvironment(for: data)
            return await candidateValidator.validate(
                candidateData: data,
                binaryURL: binaryURL,
                workingDirectoryURL: workingDirectoryURL,
                environment: credentials.environment,
                sensitiveValues: credentials.secrets + plaintextDNSPodTokens(in: data)
            )
        } catch {
            return CaddyCandidateValidationResult(isValid: false, detail: error.localizedDescription)
        }
    }

    var managedCaddyIsRunning: Bool { runtimeController.isRunning || launchAgentSnapshot.isRunning }
    var sessionCaddyIsRunning: Bool { runtimeController.isRunning }
    var managedCaddyConfigurationPath: String? {
        launchAgentSnapshot.isRunning
            ? launchAgentSnapshot.configuration?.caddyfileURL.path
            : runtimeController.configurationPath
    }

    func applicationDidLaunch() async {
        guard !didRunLaunchAction else { return }
        didRunLaunchAction = true
        await refresh()
        guard startsCaddyWithApp && !isTerminating else { return }
        guard !launchAgentSnapshot.isInstalled && !launchAgentSnapshot.isForeign else {
            runtimeActionMessage = L10n.text("Remove the old independent Caddy login service before using app-managed startup.")
            lastRuntimeActionFailed = true
            return
        }
        _ = await startManagedCaddy()
    }

    func setStartsCaddyWithApp(_ enabled: Bool) async -> String {
        if enabled {
            launchAgentSnapshot = await launchAgentController.inspect()
            guard !launchAgentSnapshot.isInstalled && !launchAgentSnapshot.isForeign else {
                lastRuntimeActionFailed = true
                return L10n.text("Remove the old independent Caddy login service before using app-managed startup.")
            }
            if !runtimeController.isRunning {
                let result = await startManagedCaddy()
                guard runtimeController.isRunning else { return result }
            }
        }
        startsCaddyWithApp = enabled
        appStartStore.saveEnabled(enabled)
        lastRuntimeActionFailed = false
        return enabled
            ? L10n.text("Caddy now starts with Caddyman and stops when Caddyman quits.")
            : L10n.text("Caddy will no longer start automatically with Caddyman.")
    }

    func stopOwnedCaddyForTermination() async -> Bool {
        isTerminating = true
        var completed = false
        defer { if !completed { isTerminating = false } }
        var attempts = 0
        while isPerformingRuntimeAction && attempts < 100 {
            try? await Task.sleep(for: .milliseconds(50))
            attempts += 1
        }
        guard !isPerformingRuntimeAction else { return false }
        do {
            launchAgentSnapshot = await launchAgentController.inspect()
            if launchAgentSnapshot.isInstalled {
                try await launchAgentController.stop()
            }
            if runtimeController.isRunning {
                try await runtimeController.stop()
            }
            certificateMonitorTask?.cancel()
            certificateMonitorTask = nil
            launchAgentSnapshot = await launchAgentController.inspect()
            completed = !managedCaddyIsRunning
            return completed
        } catch {
            runtimeActionMessage = error.localizedDescription
            lastRuntimeActionFailed = true
            return false
        }
    }

    func saveDNSPodTokenToKeychain(_ token: String) -> String {
        do {
            try credentialStore.saveToken(token)
            return L10n.text("DNSPod token saved to Keychain. The value is not shown again.")
        } catch {
            return error.localizedDescription
        }
    }

    func testDNSPodKeychainRead() -> String {
        do {
            guard try credentialStore.readToken() != nil else {
                return L10n.text("No DNSPod token is stored in Keychain.")
            }
            return L10n.text("Keychain read succeeded. The DNSPod token is available without displaying it.")
        } catch {
            return error.localizedDescription
        }
    }

    func deleteDNSPodTokenFromKeychain() -> String {
        do {
            try credentialStore.deleteToken()
            return L10n.text("DNSPod token removed from Keychain.")
        } catch {
            return error.localizedDescription
        }
    }

    func startManagedCaddy() async -> String {
        guard !isTerminating else { return CaddyLifecycleError.terminating.localizedDescription }
        guard !isPerformingRuntimeAction else { return runtimeActionMessage ?? "" }
        isPerformingRuntimeAction = true
        defer { isPerformingRuntimeAction = false }
        do {
            guard !selectedCaddyfilePath.isEmpty, case .loaded = caddyfileReadState else {
                throw SiteManagementError.targetNotLoaded
            }
            let configURL = URL(fileURLWithPath: selectedCaddyfilePath).standardizedFileURL
            let configData = try Data(contentsOf: configURL)
            let credentials = try credentialEnvironment(for: configData)
            let binaryURL = try binaryLocator.locate(explicitPath: selectedBinaryPath)
            let validation = await candidateValidator.validate(
                candidateData: configData,
                binaryURL: binaryURL,
                workingDirectoryURL: configURL.deletingLastPathComponent(),
                environment: credentials.environment,
                sensitiveValues: credentials.secrets + plaintextDNSPodTokens(in: configData)
            )
            guard validation.isValid else { throw CaddyStartValidationError(detail: validation.detail) }
            guard try CaddyfileDocument.read(from: configURL).sha256 == CaddyfileDocument.sha256(of: configData) else {
                throw SiteManagementError.externalChange
            }
            launchAgentSnapshot = await launchAgentController.inspect()
            if launchAgentSnapshot.isForeign { throw CaddyLaunchAgentError.foreignAgent }
            if launchAgentSnapshot.isInstalled {
                throw CaddyLifecycleError.independentServiceInstalled
            }
            if case .adminPortResponding = await serviceChecker.check() {
                throw CaddyRuntimeError.externalAdminAPI
            }
            recentManagedCaddyLogs = []
            latestCertificateIssuanceLog = nil
            try runtimeController.start(
                binaryURL: binaryURL,
                configurationURL: configURL,
                environment: credentials.environment,
                secrets: credentials.secrets + plaintextDNSPodTokens(in: configData),
                outputHandler: { [weak self] line in self?.consumeManagedCaddyOutput(line) }
            )
            guard await waitForManagedAdminAPI() else {
                try? await runtimeController.stop()
                throw CaddyRuntimeError.startHealthCheckFailed
            }
            runtimeActionMessage = L10n.text("Caddyman started its own Caddy process.")
            lastRuntimeActionFailed = false
            beginCertificateIssuanceFeedbackIfNeeded()
            await refresh()
            return runtimeActionMessage ?? ""
        } catch {
            runtimeActionMessage = error.localizedDescription
            lastRuntimeActionFailed = true
            return error.localizedDescription
        }
    }

    func stopManagedCaddy() async -> String {
        guard !isPerformingRuntimeAction else { return runtimeActionMessage ?? "" }
        isPerformingRuntimeAction = true
        defer { isPerformingRuntimeAction = false }
        do {
            launchAgentSnapshot = await launchAgentController.inspect()
            guard launchAgentSnapshot.isInstalled || runtimeController.isRunning else {
                throw CaddyRuntimeError.notRunning
            }
            if launchAgentSnapshot.isInstalled {
                try await launchAgentController.stop()
            }
            if runtimeController.isRunning {
                try await runtimeController.stop()
            }
            certificateMonitorTask?.cancel()
            certificateMonitorTask = nil
            certificateMonitorID = UUID()
            certificateIssuanceStatus = nil
            runtimeActionMessage = L10n.text("Caddyman stopped the Caddy process it started.")
            lastRuntimeActionFailed = false
            await refresh()
            return runtimeActionMessage ?? ""
        } catch {
            runtimeActionMessage = error.localizedDescription
            lastRuntimeActionFailed = true
            return error.localizedDescription
        }
    }

    func restartManagedCaddy() async -> String {
        guard !isPerformingRuntimeAction else { return runtimeActionMessage ?? "" }
        isPerformingRuntimeAction = true
        defer { isPerformingRuntimeAction = false }
        do {
            guard runtimeController.isRunning,
                  let configurationPath = runtimeController.configurationPath,
                  !selectedCaddyfilePath.isEmpty,
                  URL(fileURLWithPath: selectedCaddyfilePath).standardizedFileURL.path == configurationPath else {
                throw CaddyRuntimeError.notRunning
            }
            let configurationURL = URL(fileURLWithPath: configurationPath)
            let data = try Data(contentsOf: configurationURL)
            let credentials = try credentialEnvironment(for: data)
            let binaryURL = try binaryLocator.locate(explicitPath: selectedBinaryPath)
            let validation = await candidateValidator.validate(
                candidateData: data, binaryURL: binaryURL,
                workingDirectoryURL: configurationURL.deletingLastPathComponent(),
                environment: credentials.environment,
                sensitiveValues: credentials.secrets + plaintextDNSPodTokens(in: data))
            guard validation.isValid else { throw CaddyStartValidationError(detail: validation.detail) }
            guard try CaddyfileDocument.read(from: configurationURL).sha256
                    == CaddyfileDocument.sha256(of: data) else {
                throw SiteManagementError.externalChange
            }
            try await runtimeController.stop()
            recentManagedCaddyLogs = []
            latestCertificateIssuanceLog = nil
            try runtimeController.start(binaryURL: binaryURL,
                configurationURL: configurationURL,
                environment: credentials.environment,
                secrets: credentials.secrets + plaintextDNSPodTokens(in: data),
                outputHandler: { [weak self] line in self?.consumeManagedCaddyOutput(line) })
            guard await waitForManagedAdminAPI() else {
                try? await runtimeController.stop()
                throw CaddyRuntimeError.startHealthCheckFailed
            }
            runtimeActionMessage = L10n.text("Caddyman restarted its Caddy process.")
            lastRuntimeActionFailed = false
            beginCertificateIssuanceFeedbackIfNeeded()
            await refresh()
            return runtimeActionMessage ?? ""
        } catch {
            runtimeActionMessage = error.localizedDescription
            lastRuntimeActionFailed = true
            return error.localizedDescription
        }
    }

    func removeIndependentCaddyService() async -> String {
        guard !isPerformingRuntimeAction else { return runtimeActionMessage ?? "" }
        isPerformingRuntimeAction = true
        defer { isPerformingRuntimeAction = false }
        do {
            launchAgentSnapshot = await launchAgentController.inspect()
            if launchAgentSnapshot.isForeign { throw CaddyLaunchAgentError.foreignAgent }
            guard launchAgentSnapshot.isInstalled else { throw CaddyLaunchAgentError.notInstalled }
            try await launchAgentController.uninstall()
            runtimeActionMessage = L10n.text("Independent Caddy service removed. The Caddyfile and certificates were kept.")
            lastRuntimeActionFailed = false
            await refresh()
            return runtimeActionMessage ?? ""
        } catch {
            runtimeActionMessage = error.localizedDescription
            lastRuntimeActionFailed = true
            await refresh()
            return runtimeActionMessage ?? ""
        }
    }

    func setAppLoginOpen(_ enabled: Bool) -> String {
        do {
            try loginItem.setEnabled(enabled)
            loginStatus = loginItem.status()
            return loginStatus == .requiresApproval
                ? L10n.text("Approve Caddyman in System Settings > Login Items to finish setup.")
                : L10n.text("Caddyman login setting updated.")
        } catch {
            loginStatus = loginItem.status()
            return error.localizedDescription
        }
    }

    func applyMigrationPreview(_ preview: CaddyfileMigrationPreview) async -> CaddyfileMigrationApplyResult {
        let selectedTarget = URL(fileURLWithPath: selectedCaddyfilePath).standardizedFileURL
        guard !selectedCaddyfilePath.isEmpty,
              selectedTarget == preview.targetURL.standardizedFileURL else {
            return CaddyfileMigrationApplyResult(
                succeeded: false,
                detail: L10n.text("The selected target Caddyfile changed. Reopen the migration preview before applying."),
                backupURL: nil
            )
        }
        if (runtimeController.isRunning &&
            runtimeController.configurationPath == preview.targetURL.standardizedFileURL.path) ||
            (launchAgentSnapshot.isRunning &&
             launchAgentSnapshot.configuration?.caddyfileURL == preview.targetURL.standardizedFileURL) {
            return CaddyfileMigrationApplyResult(
                succeeded: false,
                detail: L10n.text("Stop Caddyman's managed Caddy before applying a migration. Use the Sites tab for live site changes."),
                backupURL: nil
            )
        }

        do {
            let currentDocument = try CaddyfileDocument.read(from: preview.targetURL)
            guard currentDocument.sha256 == preview.targetSHA256 else {
                throw CaddyfileAtomicWriteError.targetChanged
            }
        } catch {
            return CaddyfileMigrationApplyResult(succeeded: false, detail: error.localizedDescription, backupURL: nil)
        }

        let validation = await validateCaddyfileCandidate(
            preview.candidateData,
            workingDirectoryURL: preview.targetURL.deletingLastPathComponent()
        )
        guard validation.isValid else {
            return CaddyfileMigrationApplyResult(succeeded: false, detail: validation.detail, backupURL: nil)
        }

        do {
            let backupURL = try caddyfileWriter.apply(
                candidateData: preview.candidateData,
                to: preview.targetURL,
                expectedSHA256: preview.targetSHA256
            )
            initialCaddyfileHash = nil
            caddyfileHashStore.saveHash(nil)
            caddyfileExternalChangeDetected = false
            loadSelectedCaddyfile()
            return CaddyfileMigrationApplyResult(
                succeeded: true,
                detail: L10n.format("Migration applied. Backup created at %@.", backupURL.path),
                backupURL: backupURL
            )
        } catch {
            return CaddyfileMigrationApplyResult(succeeded: false, detail: error.localizedDescription, backupURL: nil)
        }
    }

    func makeSiteChangePreview(sites: [ReverseProxySite]) throws -> CaddyfileSiteChangePreview {
        guard !selectedCaddyfilePath.isEmpty else {
            throw CaddyfileSiteEditorError.managedRegionRequired
        }
        guard case .loaded(let loadedDocument) = caddyfileReadState else {
            throw SiteManagementError.targetNotLoaded
        }
        guard !caddyfileExternalChangeDetected else {
            throw SiteManagementError.externalChange
        }

        let currentDocument = try CaddyfileDocument.read(from: loadedDocument.sourceURL)
        guard currentDocument.sha256 == loadedDocument.sha256 else {
            caddyfileExternalChangeDetected = true
            throw SiteManagementError.externalChange
        }
        let editableHosts = Set(try CaddyfileSiteEditor.readManagedSites(from: currentDocument).map(\.normalizedHostname))
        let configuredBlocks = try CaddyfileDocument.parseSiteBlocks(
            in: currentDocument.content,
            allowNonSiteTopLevelContent: true
        )
        let unmanagedHosts = Set(configuredBlocks.compactMap {
            Self.normalizedHostname(inSiteAddress: $0.address)
        }.filter { !editableHosts.contains($0) })
        if let duplicate = sites.first(where: { unmanagedHosts.contains($0.normalizedHostname) }) {
            throw SiteValidationIssue.duplicateHostname(duplicate.normalizedHostname)
        }
        return try CaddyfileSiteChangePreview.make(document: currentDocument, sites: sites)
    }

    func makeSourceSiteChangePreview(
        block: CaddyfileSiteBlock,
        replacement: String
    ) throws -> CaddyfileSiteChangePreview {
        guard !selectedCaddyfilePath.isEmpty,
              case .loaded(let loadedDocument) = caddyfileReadState else {
            throw SiteManagementError.targetNotLoaded
        }
        guard !caddyfileExternalChangeDetected else { throw SiteManagementError.externalChange }
        let currentDocument = try CaddyfileDocument.read(from: loadedDocument.sourceURL)
        guard currentDocument.sha256 == loadedDocument.sha256,
              currentDocument.siteBlocks.contains(where: { $0.id == block.id && $0.sourceRange == block.sourceRange }) else {
            caddyfileExternalChangeDetected = true
            throw SiteManagementError.externalChange
        }
        return try CaddyfileSiteChangePreview.replacingSourceBlock(
            in: currentDocument,
            block: block,
            with: replacement,
            preserving: managedSiteDefinitions
        )
    }

    func makeImportChangePreview(
        directive: CaddyfileImportDirective?,
        pathPattern: String?
    ) throws -> CaddyfileSiteChangePreview {
        guard !selectedCaddyfilePath.isEmpty,
              case .loaded(let loadedDocument) = caddyfileReadState else {
            throw SiteManagementError.targetNotLoaded
        }
        guard !caddyfileExternalChangeDetected else { throw SiteManagementError.externalChange }
        let currentDocument = try CaddyfileDocument.read(from: loadedDocument.sourceURL)
        guard currentDocument.sha256 == loadedDocument.sha256 else {
            caddyfileExternalChangeDetected = true
            throw SiteManagementError.externalChange
        }

        let range: Range<Int>
        let replacement: String
        if let directive {
            guard let current = currentDocument.imports.first(where: { $0.id == directive.id && $0.pathRange == directive.pathRange }) else {
                caddyfileExternalChangeDetected = true
                throw SiteManagementError.externalChange
            }
            if let pathPattern {
                let trimmed = pathPattern.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.contains("\n"), !trimmed.contains("\r") else {
                    throw SiteManagementError.invalidImportPath
                }
                range = current.pathRange
                replacement = Self.caddyfileImportToken(trimmed)
            } else {
                range = current.lineRange
                replacement = ""
            }
        } else {
            guard let pathPattern else { throw SiteManagementError.invalidImportPath }
            let trimmed = pathPattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.contains("\n"), !trimmed.contains("\r") else {
                throw SiteManagementError.invalidImportPath
            }
            range = currentDocument.originalData.count..<currentDocument.originalData.count
            let newline = currentDocument.lineEnding == .crlf ? "\r\n" : "\n"
            let prefix = currentDocument.originalData.last == 0x0A || currentDocument.originalData.isEmpty ? "" : newline
            replacement = prefix + "import " + Self.caddyfileImportToken(trimmed) + newline
        }
        return try CaddyfileSiteChangePreview.replacingSourceRange(
            in: currentDocument,
            range: range,
            with: replacement,
            preserving: managedSiteDefinitions
        )
    }

    private static func caddyfileImportToken(_ value: String) -> String {
        guard value.contains(where: { $0.isWhitespace || $0 == "#" || $0 == "\"" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    func applySiteChangePreview(_ preview: CaddyfileSiteChangePreview) async -> CaddyfileMigrationApplyResult {
        let selectedTarget = URL(fileURLWithPath: selectedCaddyfilePath).standardizedFileURL
        guard !selectedCaddyfilePath.isEmpty,
              selectedTarget == preview.targetURL.standardizedFileURL else {
            return CaddyfileMigrationApplyResult(
                succeeded: false,
                detail: L10n.text("The selected target Caddyfile changed. Reopen the site editor before applying."),
                backupURL: nil
            )
        }

        if preview.sites.contains(where: { $0.tlsMode == .dnsPodDNS01 }) {
            guard case .ready(let installation) = inspectionState,
                  installation.binaryURL.path == selectedBinaryURLPath,
                  installation.dnsPodStatus == .available else {
                return CaddyfileMigrationApplyResult(
                    succeeded: false,
                    detail: L10n.text("DNSPod sites require a selected Caddy binary that includes dns.providers.dnspod."),
                    backupURL: nil
                )
            }
        }

        do {
            let currentDocument = try CaddyfileDocument.read(from: preview.targetURL)
            guard currentDocument.sha256 == preview.targetSHA256 else {
                throw CaddyfileAtomicWriteError.targetChanged
            }
        } catch {
            return CaddyfileMigrationApplyResult(succeeded: false, detail: error.localizedDescription, backupURL: nil)
        }

        let validation = await validateCaddyfileCandidate(
            preview.candidateData,
            workingDirectoryURL: preview.targetURL.deletingLastPathComponent()
        )
        guard validation.isValid else {
            return CaddyfileMigrationApplyResult(succeeded: false, detail: validation.detail, backupURL: nil)
        }

        do {
            let backupURL = try caddyfileWriter.apply(
                candidateData: preview.candidateData,
                to: preview.targetURL,
                expectedSHA256: preview.targetSHA256
            )
            let candidateSHA256 = CaddyfileDocument.sha256(of: preview.candidateData)
            do {
                let savedDocument = try CaddyfileDocument.read(from: preview.targetURL)
                guard savedDocument.sha256 == candidateSHA256 else {
                    throw CaddyfileSiteEditorError.readbackMismatch
                }
                if preview.shouldVerifyManagedSitesOnReadback,
                   try CaddyfileSiteEditor.readManagedSites(from: savedDocument) != preview.sites {
                    throw CaddyfileSiteEditorError.readbackMismatch
                }
            } catch {
                do {
                    _ = try restoreCaddyfileBackup(
                        backupURL: backupURL,
                        targetURL: preview.targetURL,
                        expectedCurrentSHA256: candidateSHA256
                    )
                } catch {
                    return CaddyfileMigrationApplyResult(
                        succeeded: false,
                        detail: L10n.format("Site readback failed and Caddyman could not safely restore the previous file: %@", error.localizedDescription),
                        backupURL: backupURL
                    )
                }
                return CaddyfileMigrationApplyResult(
                    succeeded: false,
                    detail: L10n.format("Site configuration was restored because readback failed: %@", error.localizedDescription),
                    backupURL: backupURL
                )
            }
            do {
                guard try CaddyfileDocument.read(from: preview.targetURL).sha256 == candidateSHA256 else {
                    throw CaddyfileAtomicWriteError.targetChanged
                }
            } catch {
                return CaddyfileMigrationApplyResult(succeeded: false, detail: error.localizedDescription, backupURL: backupURL)
            }
            var didReload = false
            if (runtimeController.isRunning &&
                runtimeController.configurationPath == preview.targetURL.standardizedFileURL.path) ||
                (launchAgentSnapshot.isRunning &&
                 launchAgentSnapshot.configuration?.caddyfileURL == preview.targetURL.standardizedFileURL) {
                do {
                    let credentials = try credentialEnvironment(for: preview.candidateData)
                    let binaryURL = try binaryLocator.locate(explicitPath: selectedBinaryPath)
                    try await reloadManagedCaddy(binaryURL: binaryURL,
                        configurationURL: preview.targetURL,
                        environment: credentials.environment,
                        secrets: credentials.secrets + plaintextDNSPodTokens(in: preview.candidateData))
                    guard await waitForManagedAdminAPI() else {
                        throw CaddyRuntimeError.startHealthCheckFailed
                    }
                    didReload = true
                } catch {
                    let previousData: Data
                    do {
                        previousData = try restoreCaddyfileBackup(
                            backupURL: backupURL,
                            targetURL: preview.targetURL,
                            expectedCurrentSHA256: candidateSHA256
                        )
                    } catch {
                        return CaddyfileMigrationApplyResult(
                            succeeded: false,
                            detail: L10n.format("Reload failed. Caddyman could not safely restore the previous file: %@", error.localizedDescription),
                            backupURL: backupURL
                        )
                    }

                    do {
                        let previousCredentials = try credentialEnvironment(for: previousData)
                        let binaryURL = try binaryLocator.locate(explicitPath: selectedBinaryPath)
                        try await reloadManagedCaddy(binaryURL: binaryURL,
                            configurationURL: preview.targetURL,
                            environment: previousCredentials.environment,
                            secrets: previousCredentials.secrets + plaintextDNSPodTokens(in: previousData))
                    } catch {
                        return CaddyfileMigrationApplyResult(
                            succeeded: false,
                            detail: L10n.format("The previous Caddyfile was restored, but its reload also failed: %@", error.localizedDescription),
                            backupURL: backupURL
                        )
                    }
                    return CaddyfileMigrationApplyResult(
                        succeeded: false,
                        detail: L10n.format("Reload failed. The previous Caddyfile was restored: %@", error.localizedDescription),
                        backupURL: backupURL
                    )
                }
            }
            resetCaddyfileChangeBaseline()
            loadSelectedCaddyfile()
            if didReload {
                if launchAgentSnapshot.isRunning {
                    certificateIssuanceStatus = L10n.text("The login service was reloaded. Certificate activity continues in the background.")
                    latestCertificateIssuanceLog = nil
                    recentManagedCaddyLogs = []
                } else {
                    beginCertificateIssuanceFeedbackIfNeeded()
                }
            }
            return CaddyfileMigrationApplyResult(
                succeeded: true,
                detail: L10n.format(
                    didReload
                        ? "Site configuration saved and reloaded. Backup created at %@."
                        : "Site configuration saved. Caddyman is not running this Caddyfile, so no service was reloaded. Backup created at %@.",
                    backupURL.path
                ),
                backupURL: backupURL
            )
        } catch {
            return CaddyfileMigrationApplyResult(succeeded: false, detail: error.localizedDescription, backupURL: nil)
        }
    }

    func loadSelectedCaddyfile() {
        guard !selectedCaddyfilePath.isEmpty else {
            caddyfileReadState = .notSelected
            return
        }

        let url = URL(fileURLWithPath: selectedCaddyfilePath)
        let previousReadState = caddyfileReadState
        let hasScopedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        caddyfileReadState = .reading
        do {
            let document = try CaddyfileDocument.read(from: url)
            if case .loaded(let previousDocument) = previousReadState,
               previousDocument.sha256 != document.sha256 {
                previousCaddyfileDocument = previousDocument
            }
            if let initialCaddyfileHash, initialCaddyfileHash != document.sha256 {
                caddyfileExternalChangeDetected = true
            } else if initialCaddyfileHash == nil {
                initialCaddyfileHash = document.sha256
                caddyfileHashStore.saveHash(document.sha256)
            }
            caddyfileReadState = .loaded(document)
        } catch {
            caddyfileReadState = .failed(error.localizedDescription)
        }
    }

    private var selectedBinaryURLPath: String? {
        switch inspectionState {
        case .ready(let installation): installation.binaryURL.path
        default: nil
        }
    }

    private func credentialEnvironment(for data: Data) throws -> (environment: [String: String], secrets: [String]) {
        let content = String(decoding: data, as: UTF8.self)
        guard content.contains("{env.DNSPOD_TOKEN}") || content.contains("{$DNSPOD_TOKEN}") else {
            return ([:], [])
        }
        guard let token = try credentialStore.readToken() else {
            throw DNSPodCredentialStoreError.keychainFailure
        }
        return (["DNSPOD_TOKEN": token], [token])
    }

    func consumeManagedCaddyOutput(_ line: String) {
        let safeLine = CaddyfileDocument.redactingCredentials(in: line)
        guard !safeLine.isEmpty else { return }
        recentManagedCaddyLogs.append(safeLine)
        if recentManagedCaddyLogs.count > 100 {
            recentManagedCaddyLogs.removeFirst(recentManagedCaddyLogs.count - 100)
        }
        Self.runtimeLogger.info("Caddy: \(safeLine, privacy: .private)")

        let lowercased = safeLine.lowercased()
        guard ["certificate", "tls.obtain", "acme", "challenge"].contains(where: lowercased.contains) else {
            return
        }
        latestCertificateIssuanceLog = safeLine
        if ["certificate obtained successfully", "certificate obtained"].contains(where: lowercased.contains) {
            certificateIssuanceStatus = L10n.text("Caddy reports that it obtained a certificate.")
        } else if ["challenge failed", "failed", "failure", "could not get certificate", "certificate error", "acme: error", "denied", "invalid"].contains(where: lowercased.contains) {
            certificateIssuanceStatus = L10n.format("Caddy reported a certificate error: %@", safeLine)
        } else {
            certificateIssuanceStatus = L10n.format("Caddy certificate activity: %@", safeLine)
        }
    }

    private func beginCertificateIssuanceFeedbackIfNeeded() {
        guard runtimeController.isRunning,
              case .loaded(let document) = caddyfileReadState,
              document.managedSites.contains(where: {
                  !$0.address.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("http://")
              }) else {
            certificateMonitorTask?.cancel()
            certificateMonitorTask = nil
            certificateIssuanceStatus = nil
            return
        }

        certificateMonitorTask?.cancel()
        let monitorID = UUID()
        certificateMonitorID = monitorID
        let waitingMessage = L10n.text("Waiting for Caddy certificate activity. Issuance can continue in the background.")
        if latestCertificateIssuanceLog == nil {
            certificateIssuanceStatus = waitingMessage
        }
        certificateMonitorTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled,
                  let self,
                  self.certificateMonitorID == monitorID,
                  self.latestCertificateIssuanceLog == nil,
                  self.certificateIssuanceStatus == waitingMessage else { return }
            self.certificateIssuanceStatus = L10n.text("No certificate-related log appeared within two minutes. Caddy may still be working; check its recent runtime logs.")
        }
    }

    private func plaintextDNSPodTokens(in data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8),
              let expression = try? NSRegularExpression(
                pattern: #"(?im)^\s*dns\s+dnspod\s+(?:token\s+)?(?:"((?:\\.|[^"])*)"|([^\s#}]+))"#
              ) else { return [] }
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        return matches.compactMap { match in
            for group in [1, 2] where match.range(at: group).location != NSNotFound {
                guard let range = Range(match.range(at: group), in: text) else { continue }
                let token = String(text[range])
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
                return token.hasPrefix("{env.") ? nil : token
            }
            return nil
        }
    }

    private func restoreCaddyfileBackup(
        backupURL: URL,
        targetURL: URL,
        expectedCurrentSHA256: String
    ) throws -> Data {
        let previousData = try Data(contentsOf: backupURL)
        let currentDocument = try CaddyfileDocument.read(from: targetURL)
        guard currentDocument.sha256 == expectedCurrentSHA256 else {
            throw CaddyfileAtomicWriteError.targetChanged
        }
        _ = try caddyfileWriter.apply(
            candidateData: previousData,
            to: targetURL,
            expectedSHA256: expectedCurrentSHA256
        )
        return previousData
    }

    private func waitForManagedAdminAPI() async -> Bool {
        for _ in 0..<20 {
            if launchAgentSnapshot.isInstalled {
                launchAgentSnapshot = await launchAgentController.inspect()
            }
            if managedCaddyIsRunning,
               case .adminPortResponding = await serviceChecker.check() { return true }
            if !launchAgentSnapshot.isInstalled && !runtimeController.isRunning { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    private func reloadManagedCaddy(binaryURL: URL, configurationURL: URL,
                                    environment: [String: String], secrets: [String]) async throws {
        if launchAgentSnapshot.isRunning,
           let configuration = launchAgentSnapshot.configuration,
           configuration.caddyfileURL == configurationURL.standardizedFileURL {
            guard configuration.binaryURL == binaryURL.standardizedFileURL else {
                throw CaddyLaunchAgentError.invalidConfiguration
            }
            try await launchAgentController.reload(configuration: configuration,
                environment: environment, secrets: secrets)
        } else {
            try await runtimeController.reload(binaryURL: binaryURL,
                configurationURL: configurationURL, environment: environment, secrets: secrets)
        }
    }

    private static func normalizedHostname(inSiteAddress address: String) -> String? {
        let firstAddress = address.split(separator: ",", omittingEmptySubsequences: true).first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let firstAddress else { return nil }
        let value = firstAddress.contains("://") ? firstAddress : "https://\(firstAddress)"
        if let components = URLComponents(string: value), let host = components.host, !host.isEmpty {
            return host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        }
        return nil
    }

    private func resetCaddyfileChangeBaseline() {
        initialCaddyfileHash = nil
        caddyfileHashStore.saveHash(nil)
        caddyfileExternalChangeDetected = false
        previousCaddyfileDocument = nil
    }

    func refresh() async {
        if isRefreshing {
            while isRefreshing && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
            return
        }
        isRefreshing = true
        serviceStatus = .checking
        inspectionState = .checking
        defer {
            isRefreshing = false
            lastRefreshDate = Date()
        }

        async let checkedService = serviceChecker.check()
        async let checkedAgent = launchAgentController.inspect()

        do {
            let binaryURL = try binaryLocator.locate(explicitPath: selectedBinaryPath)
            do {
                inspectionState = .ready(try await binaryInspector.inspect(binaryURL: binaryURL))
            } catch {
                inspectionState = .failed(error.localizedDescription)
            }
        } catch CaddyBinaryResolutionError.notFound {
            inspectionState = .noBinaryFound
        } catch CaddyBinaryResolutionError.notExecutable(let path) {
            inspectionState = .invalidSelectedPath(path)
        } catch {
            inspectionState = .failed(error.localizedDescription)
        }

        serviceStatus = await checkedService
        launchAgentSnapshot = await checkedAgent
        loginStatus = loginItem.status()
        loadSelectedCaddyfile()
    }
}

enum SiteManagementError: Error, LocalizedError, Equatable {
    case targetNotLoaded
    case externalChange
    case invalidImportPath

    var errorDescription: String? {
        switch self {
        case .targetNotLoaded:
            L10n.text("Choose and load a target Caddyfile before editing sites.")
        case .externalChange:
            L10n.text("The Caddyfile changed outside Caddyman. Reload it and review a fresh preview before saving.")
        case .invalidImportPath:
            L10n.text("Enter one import path or glob pattern on a single line.")
        }
    }
}

enum CaddyLifecycleError: Error, LocalizedError {
    case independentServiceInstalled
    case terminating

    var errorDescription: String? {
        switch self {
        case .independentServiceInstalled:
            L10n.text("Remove the old independent Caddy login service before using app-managed startup.")
        case .terminating:
            L10n.text("Caddyman is quitting and cannot start Caddy.")
        }
    }
}

private struct CaddyStartValidationError: LocalizedError {
    let detail: String
    var errorDescription: String? { L10n.format("Caddy configuration validation failed: %@", detail) }
}
