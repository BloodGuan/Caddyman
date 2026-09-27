import SwiftUI
import Observation

struct OverviewView: View {
    @Bindable var model: CaddymanAppModel
    @State private var isConfirmingStart = false
    @State private var isConfirmingRestart = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(model.lastRefreshDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.isRefreshing {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(model.isRefreshing || model.isPerformingRuntimeAction)
            }

            GroupBox("Service") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: model.managedCaddyIsRunning ? "checkmark" : "power")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(model.managedCaddyIsRunning ? Color.green : Color.secondary)
                            .frame(width: 44, height: 44)
                            .background((model.managedCaddyIsRunning ? Color.green : Color.secondary).opacity(0.11),
                                        in: RoundedRectangle(cornerRadius: 11))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(model.managedCaddyIsRunning
                                 ? L10n.text("Managed Caddy is running")
                                 : L10n.text("Managed Caddy is stopped"))
                                .font(.system(size: 18, weight: .semibold))
                            Text(model.managedCaddyIsRunning
                                 ? L10n.text("The local Admin API is responding for Caddyman's managed process.")
                                 : model.serviceStatus.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        CaddymanStatusBadge(
                            title: model.managedCaddyIsRunning ? L10n.text("Running") : L10n.text("Stopped"),
                            systemImage: model.managedCaddyIsRunning ? "circle.fill" : "circle",
                            color: model.managedCaddyIsRunning ? .green : .secondary
                        )
                    }
                    Divider()
                    LabeledContent("Caddyman process", value: model.managedCaddyIsRunning ? L10n.text("Running") : L10n.text("Stopped"))
                    LabeledContent("Service mode", value: model.launchAgentSnapshot.isInstalled
                                   ? L10n.text("Login service") : L10n.text("App session"))
                    if model.launchAgentSnapshot.isInstalled {
                        LabeledContent("Recovery", value: model.launchAgentSnapshot.isDisabled
                                       ? L10n.text("Paused after manual stop")
                                       : L10n.text("Enabled after unexpected exit"))
                    } else if model.startsCaddyWithApp {
                        LabeledContent("Lifecycle", value: L10n.text("Starts and stops with Caddyman"))
                    }
                    LabeledContent("Local admin port", value: model.serviceStatus.summary)
                    if model.managedCaddyIsRunning,
                       let configurationPath = model.managedCaddyConfigurationPath {
                        LabeledContent("Caddyman-owned process", value: configurationPath)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }

                    Divider()
                    HStack(spacing: 10) {
                        if model.isPerformingRuntimeAction {
                            ProgressView()
                                .controlSize(.small)
                            Text(model.managedCaddyIsRunning
                                 ? L10n.text("Stopping Caddy…")
                                 : L10n.text("Starting Caddy…"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else if model.managedCaddyIsRunning {
                            Button("Stop Caddy", systemImage: "stop.fill", role: .destructive) {
                                Task { _ = await model.stopManagedCaddy() }
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.isRefreshing)
                            if model.sessionCaddyIsRunning {
                                Button("Restart", systemImage: "arrow.clockwise") {
                                    isConfirmingRestart = true
                                }
                                .buttonStyle(.bordered)
                                .disabled(model.isRefreshing)
                            }
                        } else {
                            Button("Start Caddy", systemImage: "play.fill") {
                                isConfirmingStart = true
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!isCaddyfileLoaded || model.isRefreshing ||
                                      model.launchAgentSnapshot.isInstalled || model.launchAgentSnapshot.isForeign)
                        }
                        Spacer()
                        Button("Caddy Settings") {
                            model.selectedSettingsTab = .caddy
                        }
                        .buttonStyle(.link)
                        Button("Startup") {
                            model.selectedSettingsTab = .startup
                        }
                        .buttonStyle(.link)
                    }

                    if let message = model.runtimeActionMessage {
                        Label(message, systemImage: "info.circle")
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                    if model.launchAgentSnapshot.isInstalled {
                        Label("Remove the previous independent service in Startup before using app-managed Caddy.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 12) {
                summaryCard("Sites", value: siteCount, symbol: "network")
                summaryCard("Caddy", value: caddyVersion, symbol: "server.rack")
                summaryCard("DNSPod", value: dnsPodStatus, symbol: "lock.shield")
            }

            GroupBox("Site overview") {
                VStack(alignment: .leading, spacing: 8) {
                    switch model.caddyfileReadState {
                    case .notSelected:
                        Text("Choose a Caddyfile in Caddy settings to view its sites.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    case .reading:
                        ProgressView("Reading Caddyfile…")
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .textSelection(.enabled)
                    case .loaded(let document):
                        let sites = document.siteBlocks + document.importedCaddyfiles.flatMap(\.siteBlocks)
                        HStack {
                            Label(document.managedRegion.title, systemImage: document.managedRegion.symbolName)
                                .font(.callout)
                            Spacer()
                            Text(L10n.format("Sites including imports: %d", model.totalCaddyfileSiteCount))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if sites.isEmpty {
                            Text("No site blocks were found in the selected Caddyfile or its direct imports.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(sites.prefix(5).enumerated()), id: \.offset) { _, site in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(site.address)
                                        .font(.callout.weight(.medium))
                                        .textSelection(.enabled)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 8)
                                    if let upstream = site.redactedUpstream {
                                        Text(upstream)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .help(upstream)
                                    }
                                }
                            }
                            if sites.count > 5 {
                                Button("Show all sites") {
                                    model.selectedSettingsTab = .sites
                                }
                                .buttonStyle(.link)
                            }
                        }
                        if model.caddyfileExternalChangeDetected {
                            Label("External changes detected", systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let certificateIssuanceStatus = model.certificateIssuanceStatus {
                GroupBox("Certificate issuance") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(certificateIssuanceStatus)
                            .font(.callout)
                            .textSelection(.enabled)
                        if let latestLog = model.latestCertificateIssuanceLog ?? model.recentManagedCaddyLogs.last {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Latest runtime log")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                Text(latestLog)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .confirmationDialog("Start the selected Caddy configuration?", isPresented: $isConfirmingStart, titleVisibility: .visible) {
            Button("Start Caddy") {
                Task { _ = await model.startManagedCaddy() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Caddy may request or renew certificates from the configured ACME CA. DNSPod sites may create temporary DNS challenge records using the saved credential.")
        }
        .confirmationDialog("Restart Caddy?", isPresented: $isConfirmingRestart,
                            titleVisibility: .visible) {
            Button("Restart Caddy") {
                Task { _ = await model.restartManagedCaddy() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Caddy may request or renew certificates and DNSPod sites may create temporary DNS challenge records.")
        }
        .task {
            if model.lastRefreshDate == nil {
                await model.refresh()
            }
        }
    }

    private var isCaddyfileLoaded: Bool {
        if case .loaded = model.caddyfileReadState { return model.managedSiteReadError == nil }
        return false
    }

    private func summaryCard(_ title: LocalizedStringKey, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            Text(value)
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(title)
                .font(.callout.weight(.medium))
        }
        .frame(maxWidth: .infinity, minHeight: 105, alignment: .leading)
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private var siteCount: String {
        if case .loaded = model.caddyfileReadState { return String(model.totalCaddyfileSiteCount) }
        return "—"
    }

    private var caddyVersion: String {
        if case .ready(let installation) = model.inspectionState { return installation.version }
        return "—"
    }

    private var dnsPodStatus: String {
        if case .ready(let installation) = model.inspectionState { return installation.dnsPodStatus.title }
        return "—"
    }
}
