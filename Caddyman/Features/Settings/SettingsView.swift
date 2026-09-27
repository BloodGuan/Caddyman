import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var model: CaddymanAppModel
    @State private var isChoosingBinary = false
    @State private var isChoosingCaddyfile = false
    @State private var isChoosingImportSource = false
    @State private var importSourceDocument: CaddyfileDocument?
    @State private var migrationPreview: CaddyfileMigrationPreview?
    @State private var migrationPreviewError: String?
    @State private var keychainTokenDraft = ""
    @State private var keychainMessage: String?
    @State private var startupMessage: String?
    @State private var isConfirmingCaddyAutoStart = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(width: 1)
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(pageTitle)
                            .font(.system(size: 27, weight: .bold, design: .rounded))
                        Text(pageSubtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    CaddymanStatusBadge(
                        title: model.managedCaddyIsRunning ? L10n.text("Running") : L10n.text("Stopped"),
                        systemImage: model.managedCaddyIsRunning ? "circle.fill" : "circle",
                        color: model.managedCaddyIsRunning ? .green : .secondary
                    )
                }
                .padding(.horizontal, 30)
                .padding(.top, 28)
                .padding(.bottom, 21)

                Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)

                ScrollView(.vertical) {
                    pageContent
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.horizontal, 30)
                        .padding(.top, 25)
                        .padding(.bottom, 32)
                }
                .id(model.selectedSettingsTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: 980, height: 680, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .background {
            SettingsWindowTitleHider()
                .frame(width: 0, height: 0)
        }
        .groupBoxStyle(CaddymanCardStyle())
        .fileImporter(
            isPresented: $isChoosingBinary,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await model.setSelectedBinaryPath(url.path) }
        }
        .fileImporter(
            isPresented: $isChoosingCaddyfile,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            model.setSelectedCaddyfilePath(url.path)
        }
        .fileImporter(
            isPresented: $isChoosingImportSource,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let hasScopedAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasScopedAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                importSourceDocument = try CaddyfileDocument.read(from: url)
                migrationPreviewError = nil
            } catch {
                importSourceDocument = nil
                migrationPreviewError = error.localizedDescription
            }
        }
        .sheet(item: $migrationPreview) { preview in
            CaddyfileMigrationPreviewSheet(
                preview: preview,
                validateCandidate: { candidateData, workingDirectoryURL in
                    await model.validateCaddyfileCandidate(candidateData, workingDirectoryURL: workingDirectoryURL)
                },
                applyCandidate: { preview in
                    await model.applyMigrationPreview(preview)
                }
            )
        }
        .task {
            await model.refresh()
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch model.selectedSettingsTab {
        case .overview:
            OverviewView(model: model)
        case .sites:
            SiteManagementView(
                model: model,
                importSourcePath: importSourceDocument?.sourceURL.path,
                importError: migrationPreviewError,
                chooseImportSource: { isChoosingImportSource = true },
                previewImport: createMigrationPreview
            )
        case .caddy:
            caddySettings
        case .startup:
            startupSettings
        case .dnsPod:
            dnsPodSettings
        case .about:
            aboutSettings
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "server.rack")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.tint, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Caddyman")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("Caddy Manager")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 19)
            .padding(.top, 29)
            .padding(.bottom, 32)

            sidebarItem("Overview", systemImage: "square.grid.2x2", tab: .overview)
            sidebarItem("Sites", systemImage: "network", tab: .sites)
            sidebarItem("Caddy", systemImage: "server.rack", tab: .caddy)
            Rectangle().fill(Color.primary.opacity(0.08))
                .frame(height: 1)
                .padding(.horizontal, 19)
                .padding(.vertical, 14)
            sidebarItem("Startup", systemImage: "power.circle", tab: .startup)
            sidebarItem("DNSPod", systemImage: "key.horizontal", tab: .dnsPod)
            Spacer()
            HStack(spacing: 7) {
                Circle()
                    .fill(model.managedCaddyIsRunning ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(model.managedCaddyIsRunning
                     ? L10n.text("Managed Caddy is running")
                     : L10n.text("Managed Caddy is stopped"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 21)
            .padding(.bottom, 15)
            Rectangle().fill(Color.primary.opacity(0.08))
                .frame(height: 1)
                .padding(.horizontal, 19)
                .padding(.bottom, 11)
            sidebarItem("About", systemImage: "info.circle", tab: .about)
                .padding(.bottom, 12)
        }
        .frame(width: 214)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.56))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings section")
    }

    private func sidebarItem(_ title: LocalizedStringKey, systemImage: String, tab: CaddymanSettingsTab) -> some View {
        Button {
            model.selectedSettingsTab = tab
        } label: {
            Label {
                Text(title)
                    .font(.system(size: 13, weight: model.selectedSettingsTab == tab ? .semibold : .medium))
            } icon: {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 19)
            }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.selectedSettingsTab == tab ? Color.accentColor : Color.primary)
        .background(model.selectedSettingsTab == tab ? Color.accentColor.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 9))
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
        .accessibilityAddTraits(model.selectedSettingsTab == tab ? .isSelected : [])
    }

    private var pageTitle: LocalizedStringKey {
        switch model.selectedSettingsTab {
        case .overview: "Overview"
        case .sites: "Sites"
        case .caddy: "Caddy"
        case .startup: "Startup"
        case .dnsPod: "DNSPod"
        case .about: "About"
        }
    }

    private var pageSubtitle: LocalizedStringKey {
        switch model.selectedSettingsTab {
        case .overview: "Service health and controls"
        case .sites: "Reverse proxy sites in the selected Caddyfile"
        case .caddy: "Executable and configuration file"
        case .startup: "Start together, stop together"
        case .dnsPod: "DNS challenge credentials"
        case .about: "Application details"
        }
    }

    private var startupSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Caddy follows Caddyman") {
                VStack(alignment: .leading, spacing: 12) {
                    Label(model.launchAgentSnapshot.isInstalled && model.startsCaddyWithApp
                          ? L10n.text("Blocked by previous service")
                          : (model.startsCaddyWithApp
                             ? L10n.text("Starts with the app") : L10n.text("Manual start")),
                          systemImage: model.launchAgentSnapshot.isInstalled && model.startsCaddyWithApp
                            ? "exclamationmark.triangle.fill"
                            : (model.startsCaddyWithApp ? "checkmark.circle.fill" : "pause.circle"))
                        .foregroundStyle(model.launchAgentSnapshot.isInstalled && model.startsCaddyWithApp
                                         ? .orange : (model.startsCaddyWithApp ? .green : .secondary))
                    Text("When Caddyman opens, it starts the selected Caddyfile. Quitting Caddyman stops the Caddy process it owns.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button(model.startsCaddyWithApp
                               ? L10n.text("Disable automatic start") : L10n.text("Start Caddy with Caddyman")) {
                            if model.startsCaddyWithApp {
                                Task { startupMessage = await model.setStartsCaddyWithApp(false) }
                            } else {
                                isConfirmingCaddyAutoStart = true
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isPerformingRuntimeAction ||
                                  (!model.startsCaddyWithApp &&
                                   (model.launchAgentSnapshot.isInstalled || model.launchAgentSnapshot.isForeign)))
                        if model.isPerformingRuntimeAction { ProgressView().controlSize(.small) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox("Caddyman app") {
                VStack(alignment: .leading, spacing: 12) {
                    Label(model.loginStatus == .requiresApproval
                          ? L10n.text("Needs approval")
                          : (model.loginStatus == .enabled
                             ? L10n.text("Opens at login") : L10n.text("Does not open at login")),
                          systemImage: "menubar.rectangle")
                    Text("Opens Caddyman in the menu bar when you log in. If Caddy follows Caddyman, it starts after the app opens.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if model.loginStatus == .requiresApproval {
                        Label("Approve Caddyman in System Settings > Login Items to finish setup.",
                              systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Button(model.loginStatus == .enabled || model.loginStatus == .requiresApproval
                           ? L10n.text("Disable app login") : L10n.text("Open app at login")) {
                        startupMessage = model.setAppLoginOpen(
                            !(model.loginStatus == .enabled || model.loginStatus == .requiresApproval))
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            if model.launchAgentSnapshot.isInstalled || model.launchAgentSnapshot.isForeign {
                GroupBox("Previous independent service") {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("An older Caddy login service is installed. It can keep running after Caddyman quits.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                        Text("Remove it before enabling app-managed startup. Its Caddyfile and certificates will be kept.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let issue = model.launchAgentSnapshot.issue {
                            Text(issue).font(.caption).textSelection(.enabled)
                        }
                        if model.launchAgentSnapshot.isInstalled {
                            Button("Remove independent service") {
                                Task { startupMessage = await model.removeIndependentCaddyService() }
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.isPerformingRuntimeAction)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            }

            if let startupMessage {
                Label(startupMessage, systemImage: "info.circle")
                    .font(.caption)
                    .textSelection(.enabled)
            }
        }
        .confirmationDialog("Start Caddy with Caddyman?", isPresented: $isConfirmingCaddyAutoStart,
                            titleVisibility: .visible) {
            Button("Enable and start now") {
                Task { startupMessage = await model.setStartsCaddyWithApp(true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Caddy may request certificates and DNSPod sites may create temporary DNS records. Caddyman validates the selected Caddyfile before starting it.")
        }
    }

    private var aboutSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Caddyman") {
                VStack(alignment: .leading, spacing: 12) {
                    Label("A local, menu bar manager for one Caddy instance.", systemImage: "server.rack")
                        .font(.callout)
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                    LabeledContent("Bundle ID", value: Bundle.main.bundleIdentifier ?? "com.blood.caddyman")
                    Text("Reverse proxy sites are stored in the selected Caddyfile. Caddyman preserves text outside its managed region.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Some interface patterns were adapted from Caddock with permission. Caddyman is an independent project.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var caddySettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Caddy binary") {
                VStack(alignment: .leading, spacing: 10) {
                    fileLocation(
                        path: model.selectedBinaryPath,
                        placeholder: "Automatic Homebrew discovery",
                        emptyDetail: "Caddyman looks for an installed Caddy binary.",
                        symbol: "server.rack"
                    )

                    HStack {
                        Button("Choose Caddy…") {
                            isChoosingBinary = true
                        }
                        .controlSize(.small)

                        Button("Use automatic discovery") {
                            Task { await model.useAutomaticDiscovery() }
                        }
                        .controlSize(.small)
                        .disabled(model.selectedBinaryPath.isEmpty)

                        Spacer()

                        Button("Refresh", systemImage: "arrow.clockwise") {
                            Task { await model.refresh() }
                        }
                        .controlSize(.small)
                        .disabled(model.isRefreshing)
                    }

                    inspectionSummary
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Selected Caddyfile") {
                VStack(alignment: .leading, spacing: 10) {
                    fileLocation(
                        path: model.selectedCaddyfilePath,
                        placeholder: "No Caddyfile selected.",
                        emptyDetail: "Choose the configuration Caddyman should manage.",
                        symbol: "doc.text"
                    )

                    HStack {
                        Button("Choose Caddyfile…") {
                            isChoosingCaddyfile = true
                        }
                        .controlSize(.small)

                        Button("Reload", systemImage: "arrow.clockwise") {
                            model.acceptExternalCaddyfileChanges()
                        }
                        .controlSize(.small)
                        .disabled(model.selectedCaddyfilePath.isEmpty || model.caddyfileReadState == .reading)

                        Spacer()

                        Button("Clear") {
                            model.clearSelectedCaddyfile()
                        }
                        .controlSize(.small)
                        .disabled(model.selectedCaddyfilePath.isEmpty)
                    }

                    caddyfileSummary
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Caddy detection") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Caddyman checks the selected binary for its version and DNSPod support. Site options follow the capabilities it reports.")
                        .font(.callout)
                    Text("Select an existing Caddy executable you trust. Caddyman never downloads or replaces it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    DisclosureGroup("Detection details") {
                        Text("caddy version · caddy list-modules --json · dns.providers.dnspod")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(.top, 6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var dnsPodSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            if case .ready(let installation) = model.inspectionState {
                CaddymanStatusBadge(
                    title: installation.dnsPodStatus.title,
                    systemImage: installation.dnsPodStatus == .available
                        ? "checkmark.circle.fill" : "exclamationmark.circle",
                    color: installation.dnsPodStatus == .available ? .green : .orange
                )
            }
            GroupBox("DNSPod credential") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Store the APP_ID,APP_TOKEN value in macOS Keychain. Caddyman injects it into its own Caddy child process only; it is never written to preferences, command arguments, logs, or a LaunchAgent.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SecureField("APP_ID,APP_TOKEN", text: $keychainTokenDraft)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Save to Keychain") {
                            keychainMessage = model.saveDNSPodTokenToKeychain(keychainTokenDraft)
                            keychainTokenDraft = ""
                        }
                        .disabled(keychainTokenDraft.isEmpty)
                        Button("Test Keychain Read") {
                            keychainMessage = model.testDNSPodKeychainRead()
                        }
                        Button("Remove token", role: .destructive) {
                            keychainMessage = model.deleteDNSPodTokenFromKeychain()
                        }
                        Spacer()
                    }
                    if let keychainMessage {
                        Text(keychainMessage)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("DNS-01 certificates") {
                Text("DNSPod DNS-01 is available only when the selected Caddy binary includes the DNSPod module. Site certificate mode is configured from the Sites page.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func fileLocation(
        path: String,
        placeholder: LocalizedStringKey,
        emptyDetail: LocalizedStringKey,
        symbol: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 38, height: 38)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                if path.isEmpty {
                    Text(placeholder)
                        .font(.callout.weight(.semibold))
                    Text(emptyDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    let url = URL(fileURLWithPath: path)
                    Text(url.lastPathComponent)
                        .font(.callout.weight(.semibold))
                    Text(url.deletingLastPathComponent().path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.70), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private func createMigrationPreview() {
        guard let source = importSourceDocument else { return }
        guard !model.selectedCaddyfilePath.isEmpty else {
            migrationPreviewError = L10n.text("Choose a target Caddyfile before previewing the import.")
            return
        }

        let sourceURL = source.sourceURL
        let hasSourceAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasSourceAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let targetURL = URL(fileURLWithPath: model.selectedCaddyfilePath)
            let hasScopedAccess = targetURL.startAccessingSecurityScopedResource()
            defer {
                if hasScopedAccess {
                    targetURL.stopAccessingSecurityScopedResource()
                }
            }
            let latestSource = try CaddyfileDocument.read(from: sourceURL)
            let target = try CaddyfileDocument.read(from: targetURL)
            migrationPreview = try CaddyfileMigrationPreview.make(source: latestSource, target: target)
            migrationPreviewError = nil
        } catch {
            migrationPreviewError = error.localizedDescription
            migrationPreview = nil
        }
    }

    @ViewBuilder
    private var caddyfileSummary: some View {
        switch model.caddyfileReadState {
        case .notSelected:
            Text("Choose a Caddyfile to view the Caddyman-managed region.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .reading:
            ProgressView("Reading Caddyfile…")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .textSelection(.enabled)
        case .loaded(let document):
            if model.caddyfileExternalChangeDetected {
                Label("External changes detected", systemImage: "arrow.triangle.2.circlepath")
                    .font(.callout.weight(.medium))
                Text("The Caddyfile content changed since it was first read. This view shows the latest file contents.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Label(document.managedRegion.title, systemImage: document.managedRegion.symbolName)
                .font(.callout)
                .textSelection(.enabled)

            LabeledContent("Sites including imports", value: "\(model.totalCaddyfileSiteCount)")
            LabeledContent("Line endings", value: lineEndingDescription(document.lineEnding))
            LabeledContent("SHA-256", value: String(document.sha256.prefix(16)))
                .font(.caption.monospaced())

            if case .valid = document.managedRegion {
                DisclosureGroup("Preview managed region") {
                    ScrollView(.vertical) {
                        Text(document.redactedManagedRegionText.isEmpty
                            ? L10n.text("No managed-region content.")
                            : document.redactedManagedRegionText)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                }
            }

            if model.caddyfileExternalChangeDetected,
               let previousDocument = model.previousCaddyfileDocument {
                DisclosureGroup("Compare managed region") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Previous read")
                            .font(.caption.weight(.semibold))
                        Text(previousDocument.redactedManagedRegionText.isEmpty
                            ? L10n.text("No managed-region content.")
                            : previousDocument.redactedManagedRegionText)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Divider()

                        Text("Latest read")
                            .font(.caption.weight(.semibold))
                        Text(document.redactedManagedRegionText.isEmpty
                            ? L10n.text("No managed-region content.")
                            : document.redactedManagedRegionText)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 4)
                }
            }

            Text("Reading this file does not change it. Site changes require a complete diff review, Caddy validation, backup, and explicit apply confirmation.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func lineEndingDescription(_ lineEnding: CaddyfileLineEnding) -> String {
        switch lineEnding {
        case .lf: "LF"
        case .crlf: "CRLF"
        case .mixed: L10n.text("Mixed")
        case .none: L10n.text("None")
        }
    }

    @ViewBuilder
    private var inspectionSummary: some View {
        switch model.inspectionState {
        case .ready(let installation):
            LabeledContent("Version", value: installation.version)
            LabeledContent("Binary", value: installation.binaryURL.path)
            LabeledContent("DNSPod DNS provider", value: installation.dnsPodStatus.title)
            Text(installation.dnsPodStatus.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .checking:
            ProgressView("Checking selected Caddy binary…")
        case .noBinaryFound:
            Label("No executable found at /opt/homebrew/bin/caddy or /usr/local/bin/caddy.", systemImage: "info.circle")
                .font(.callout)
        case .invalidSelectedPath(let path):
            Label(L10n.format("Selected file is not executable: %@", path), systemImage: "exclamationmark.triangle")
                .font(.callout)
                .textSelection(.enabled)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .textSelection(.enabled)
        case .notChecked:
            Text("Choose a Caddy binary or refresh to detect a Homebrew installation.")
                .foregroundStyle(.secondary)
        }
    }

}

private struct CaddyfileMigrationPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isValidating = false
    @State private var isApplying = false
    @State private var isConfirmingApply = false
    @State private var validationResult: CaddyCandidateValidationResult?
    @State private var applyResult: CaddyfileMigrationApplyResult?
    let preview: CaddyfileMigrationPreview
    let validateCandidate: (Data, URL) async -> CaddyCandidateValidationResult
    let applyCandidate: (CaddyfileMigrationPreview) async -> CaddyfileMigrationApplyResult

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Caddyfile migration preview", systemImage: "doc.text.magnifyingglass")
                .font(.title2.weight(.semibold))

            LabeledContent("Source Caddyfile", value: preview.sourceURL.path)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            LabeledContent("Target Caddyfile", value: preview.targetURL.path)
                .font(.caption.monospaced())
                .textSelection(.enabled)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(L10n.format("Sites to import: %d", preview.sites.count))
                    .font(.callout.weight(.medium))
                ForEach(preview.sites) { site in
                    Text(site.address)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Text("Complete proposed diff")
                .font(.headline)

            ScrollView([.horizontal, .vertical]) {
                Text(preview.diffText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, minHeight: 280, alignment: .topLeading)
            }
            .caddymanDiffSurface()

            if let validationResult {
                Label(
                    validationResult.detail,
                    systemImage: validationResult.isValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(validationResult.isValid ? .green : .orange)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let applyResult {
                Label(
                    applyResult.detail,
                    systemImage: applyResult.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(applyResult.succeeded ? .green : .orange)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Label("Preview only. No file has been changed.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Validate with selected Caddy", systemImage: "checkmark.shield") {
                    Task {
                        isValidating = true
                        let targetURL = preview.targetURL
                        let hasScopedAccess = targetURL.startAccessingSecurityScopedResource()
                        defer {
                            if hasScopedAccess {
                                targetURL.stopAccessingSecurityScopedResource()
                            }
                        }
                        validationResult = await validateCandidate(
                            preview.candidateData,
                            targetURL.deletingLastPathComponent()
                        )
                        isValidating = false
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isValidating)
                if isValidating {
                    ProgressView()
                        .controlSize(.small)
                }
                if validationResult?.isValid == true, applyResult?.succeeded != true {
                    Button("Back Up and Apply…", systemImage: "externaldrive.badge.timemachine") {
                        isConfirmingApply = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isApplying || isValidating)
                }
                if isApplying {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 560)
        .alert("Apply this migration?", isPresented: $isConfirmingApply) {
            Button("Cancel", role: .cancel) {}
            Button("Back Up and Apply", role: .destructive) {
                Task {
                    isApplying = true
                    let hasScopedAccess = preview.targetURL.startAccessingSecurityScopedResource()
                    defer {
                        if hasScopedAccess {
                            preview.targetURL.stopAccessingSecurityScopedResource()
                        }
                    }
                    applyResult = await applyCandidate(preview)
                    isApplying = false
                }
            }
        } message: {
            Text("Caddyman will validate the candidate again, save a protected copy of the current target, and atomically replace only that file. The imported source file will not be changed.")
        }
    }
}
