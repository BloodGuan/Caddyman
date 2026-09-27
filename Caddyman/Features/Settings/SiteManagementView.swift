import SwiftUI
import UniformTypeIdentifiers

struct SiteManagementView: View {
    @Bindable var model: CaddymanAppModel
    let importSourcePath: String?
    let importError: String?
    let chooseImportSource: () -> Void
    let previewImport: () -> Void
    @State private var editingSite: ReverseProxySite?
    @State private var isAddingSite = false
    @State private var sitePendingDeletion: ReverseProxySite?
    @State private var editingSourceSite: CaddyfileSiteBlock?
    @State private var importEditorRequest: ImportEditorRequest?
    @State private var collapsedImportedFiles: Set<String> = []
    @State private var changePreview: CaddyfileSiteChangePreview?
    @State private var editorError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            activeFileSummary
            siteListCard
            importsCard
            mergeCard
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .sheet(item: $editingSite) { site in
            SiteEditorSheet(
                site: site,
                isNewSite: isAddingSite,
                dnsPodAvailable: dnsPodAvailable,
                existingSites: model.managedSiteDefinitions,
                onSave: preparePreview
            )
        }
        .sheet(item: $editingSourceSite) { site in
            CaddyfileBlockEditorSheet(block: site) { replacement in
                do {
                    changePreview = try model.makeSourceSiteChangePreview(block: site, replacement: replacement)
                    editingSourceSite = nil
                } catch {
                    editorError = error.localizedDescription
                }
            }
        }
        .sheet(item: $importEditorRequest) { request in
            CaddyfileImportEditorSheet(
                initialPath: request.directive?.pathPattern ?? "",
                importingCaddyfileURL: URL(fileURLWithPath: model.selectedCaddyfilePath)
            ) { path in
                prepareImportChange(request.directive, pathPattern: path)
                importEditorRequest = nil
            }
        }
        .sheet(item: $changePreview) { preview in
            SiteChangeReviewSheet(
                preview: preview,
                validate: { data, directory in
                    await model.validateCaddyfileCandidate(data, workingDirectoryURL: directory)
                },
                apply: { preview in
                    await model.applySiteChangePreview(preview)
                }
            )
        }
        .alert("Delete this site?", isPresented: Binding(
            get: { sitePendingDeletion != nil },
            set: { if !$0 { sitePendingDeletion = nil } }
        )) {
            Button("Cancel", role: .cancel) { sitePendingDeletion = nil }
            Button("Review Deletion…", role: .destructive) {
                guard let sitePendingDeletion else { return }
                do {
                    changePreview = try model.makeSiteChangePreview(
                        sites: model.managedSiteDefinitions.filter { $0.id != sitePendingDeletion.id }
                    )
                } catch {
                    editorError = error.localizedDescription
                }
                self.sitePendingDeletion = nil
            }
        } message: {
            Text("The site will be removed from the Caddyman managed region after you review, validate, and confirm the complete diff.")
        }
        .alert("Could not prepare site changes", isPresented: Binding(
            get: { editorError != nil },
            set: { if !$0 { editorError = nil } }
        )) {
            Button("OK", role: .cancel) { editorError = nil }
        } message: {
            Text(editorError ?? "")
        }
    }

    private var activeFileSummary: some View {
        HStack(spacing: 14) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 48, height: 48)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 4) {
                Text("Current Caddyfile")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                if model.selectedCaddyfilePath.isEmpty {
                    Text("No Caddyfile selected")
                        .font(.callout.weight(.semibold))
                } else {
                    let url = URL(fileURLWithPath: model.selectedCaddyfilePath)
                    Text(url.lastPathComponent)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(url.deletingLastPathComponent().path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 12)
            if isCaddyfileLoaded {
                CaddymanStatusBadge(
                    title: L10n.format("%d sites", model.totalCaddyfileSiteCount),
                    systemImage: "globe",
                    color: .accentColor
                )
            } else {
                Button("Caddy Settings") { model.selectedSettingsTab = .caddy }
                    .buttonStyle(.bordered)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.accentColor.opacity(0.13), lineWidth: 1)
        }
    }

    private var mergeCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, height: 40)
                        .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(importSourcePath.map { URL(fileURLWithPath: $0).lastPathComponent }
                             ?? L10n.text("No source Caddyfile selected."))
                            .font(.callout.weight(.medium))
                        if let importSourcePath {
                            Text(importSourcePath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text("Select a source file to preview the sites that can be copied.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                HStack {
                    Button("Choose source Caddyfile…", systemImage: "folder", action: chooseImportSource)
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Preview merge", systemImage: "doc.text.magnifyingglass", action: previewImport)
                        .buttonStyle(.borderedProminent)
                        .disabled(importSourcePath == nil || model.selectedCaddyfilePath.isEmpty)
                }
                if let importError {
                    Label(importError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
        } label: {
            SiteSectionLabel(
                title: "Merge sites from another file",
                subtitle: "Copy site blocks into the current Caddyfile after reviewing the changes.",
                symbol: "square.on.square"
            )
        }
    }

    private var siteListCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                if let readError = model.managedSiteReadError {
                    Label(readError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                if model.caddyfileExternalChangeDetected {
                    HStack {
                        Label("The Caddyfile changed outside Caddyman. Reload it before editing.", systemImage: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Reload Caddyfile") { model.acceptExternalCaddyfileChanges() }
                            .controlSize(.small)
                    }
                }
                switch model.caddyfileReadState {
                case .loaded(let document):
                    if document.siteBlocks.isEmpty {
                        SiteEmptyState(
                            title: "No sites in this Caddyfile",
                            detail: "Add a site here, or view sites from imported files below.",
                            symbol: "globe"
                        )
                    } else {
                        ForEach(Array(document.siteBlocks.enumerated()), id: \.element.id) { index, block in
                            if index > 0 { Divider() }
                            if let site = structuredSite(matching: block) {
                                siteRow(site)
                            } else {
                                sourceSiteRow(block)
                            }
                        }
                    }
                case .reading:
                    ProgressView("Reading Caddyfile…")
                        .frame(maxWidth: .infinity, minHeight: 110)
                case .notSelected:
                    SiteEmptyState(
                        title: "Choose a Caddyfile to begin",
                        detail: "Select the active configuration in Caddy Settings.",
                        symbol: "doc.badge.plus"
                    )
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 12) {
                SiteSectionLabel(
                    title: "Sites in this file",
                    subtitle: "Manage site blocks stored directly in the selected Caddyfile.",
                    symbol: "globe"
                )
                Spacer(minLength: 12)
                Button("Add Site…", systemImage: "plus") {
                    editingSite = ReverseProxySite()
                    isAddingSite = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isCaddyfileLoaded || model.caddyfileExternalChangeDetected)
            }
        }
    }

    private var importsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                if case .loaded(let document) = model.caddyfileReadState {
                    if document.imports.isEmpty {
                        SiteEmptyState(
                            title: "No imported files yet",
                            detail: "Add an import to include another Caddyfile without copying its contents.",
                            symbol: "doc.on.doc"
                        )
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(document.imports.enumerated()), id: \.element.id) { index, directive in
                                if index > 0 { Divider() }
                                importDirectiveRow(directive)
                            }
                        }
                    }

                    if !document.imports.isEmpty, document.importedCaddyfiles.isEmpty {
                        Label("No external files matched these imports. Named snippets remain supported by Caddy.", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !document.importedCaddyfiles.isEmpty {
                        Divider()
                        HStack {
                            Text("Sites from imported files")
                                .font(.callout.weight(.semibold))
                            Spacer()
                            CaddymanStatusBadge(title: L10n.text("Read-only"), systemImage: "eye", color: .secondary)
                        }
                        ForEach(document.importedCaddyfiles) { imported in
                            importedFileCard(imported)
                        }
                    }
                } else if !isCaddyfileLoaded {
                    SiteEmptyState(
                        title: "Import references are unavailable",
                        detail: "Choose and load a Caddyfile to inspect its imports.",
                        symbol: "doc.questionmark"
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 12) {
                SiteSectionLabel(
                    title: "Imported Caddyfiles",
                    subtitle: "Manage top-level import references; imported content is read-only.",
                    symbol: "square.stack.3d.up"
                )
                Spacer(minLength: 12)
                Button("Add Import…", systemImage: "plus") {
                    importEditorRequest = ImportEditorRequest(directive: nil)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isCaddyfileLoaded || model.caddyfileExternalChangeDetected)
            }
        }
    }

    private func importDirectiveRow(_ directive: CaddyfileImportDirective) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(directive.pathPattern)
                    .font(.callout.weight(.medium))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Import reference")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Menu {
                Button("Edit Path…", systemImage: "pencil") {
                    importEditorRequest = ImportEditorRequest(directive: directive)
                }
                Button("Delete Import…", systemImage: "trash", role: .destructive) {
                    prepareImportChange(directive, pathPattern: nil)
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .disabled(model.caddyfileExternalChangeDetected)
        }
        .padding(.vertical, 6)
    }

    private func importedFileCard(_ imported: ImportedCaddyfileSites) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { !collapsedImportedFiles.contains(imported.id) },
            set: { expanded in
                if expanded { collapsedImportedFiles.remove(imported.id) }
                else { collapsedImportedFiles.insert(imported.id) }
            }
        )) {
            VStack(alignment: .leading, spacing: 10) {
                Divider()
                if let error = imported.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                } else if imported.siteBlocks.isEmpty {
                    Text("No site blocks found in this imported file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(imported.siteBlocks.enumerated()), id: \.element.id) { index, block in
                        if index > 0 { Divider() }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(block.address)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Text(block.redactedUpstream ?? L10n.text("Custom Caddyfile directives"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: "doc.text")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text(imported.url.lastPathComponent)
                        .font(.callout.weight(.semibold))
                    Text(imported.url.deletingLastPathComponent().path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(L10n.format("%d sites", imported.siteBlocks.count))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(13)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private func structuredSite(matching block: CaddyfileSiteBlock) -> ReverseProxySite? {
        model.managedSiteDefinitions.first { site in
            let host = site.normalizedHostname.contains(":") ? "[\(site.normalizedHostname)]" : site.normalizedHostname
            let port = site.port.isEmpty ? "" : ":\(site.port)"
            let scheme = site.tlsMode == .httpOnly ? "http://" : ""
            return block.address.caseInsensitiveCompare("\(scheme)\(host)\(port)") == .orderedSame
        }
    }

    private func sourceSiteRow(_ block: CaddyfileSiteBlock) -> some View {
        HStack(spacing: 13) {
            Image(systemName: "curlybraces")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(block.address)
                    .font(.callout.weight(.semibold))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(block.redactedUpstream ?? L10n.text("Custom Caddyfile directives"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            CaddymanStatusBadge(
                title: block.isInsideManagedRegion ? L10n.text("Managed region") : L10n.text("Caddyfile"),
                systemImage: block.isInsideManagedRegion ? "checkmark.circle" : "doc.text",
                color: block.isInsideManagedRegion ? .accentColor : .secondary
            )
            Menu {
                Button("Edit", systemImage: "pencil") { editingSourceSite = block }
                Button("Delete", systemImage: "trash", role: .destructive) {
                    prepareSourceBlockChange(block, replacement: "")
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .disabled(model.caddyfileExternalChangeDetected)
        }
        .padding(.vertical, 5)
    }

    private func prepareSourceBlockChange(_ block: CaddyfileSiteBlock, replacement: String) {
        do {
            changePreview = try model.makeSourceSiteChangePreview(block: block, replacement: replacement)
        } catch {
            editorError = error.localizedDescription
        }
    }

    private func prepareImportChange(_ directive: CaddyfileImportDirective?, pathPattern: String?) {
        do {
            changePreview = try model.makeImportChangePreview(directive: directive, pathPattern: pathPattern)
        } catch {
            editorError = error.localizedDescription
        }
    }

    private func siteRow(_ site: ReverseProxySite) -> some View {
        HStack(spacing: 13) {
            Image(systemName: "globe")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(site.normalizedHostname + (site.port.isEmpty ? "" : ":\(site.port)"))
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(CaddyfileManagedSite(address: site.normalizedHostname, upstream: site.upstream).redactedUpstream ?? site.upstream)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            CaddymanStatusBadge(
                title: tlsTitle(site),
                systemImage: site.tlsMode == .httpOnly ? "lock.open" : "lock.fill",
                color: site.tlsMode == .httpOnly ? .secondary : .green
            )
            Menu {
                Button("Edit", systemImage: "pencil") {
                    editingSite = site
                    isAddingSite = false
                }
                Button("Delete", systemImage: "trash", role: .destructive) {
                    sitePendingDeletion = site
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help(L10n.text("Edit"))
            .disabled(model.caddyfileExternalChangeDetected || model.managedSiteReadError != nil)
        }
        .padding(.vertical, 5)
    }

    private var isCaddyfileLoaded: Bool {
        if case .loaded = model.caddyfileReadState { return model.managedSiteReadError == nil }
        return false
    }

    private var dnsPodAvailable: Bool {
        guard case .ready(let installation) = model.inspectionState else { return false }
        return installation.dnsPodStatus == .available
    }

    private func preparePreview(_ site: ReverseProxySite) {
        do {
            var sites = model.managedSiteDefinitions
            if let index = sites.firstIndex(where: { $0.id == site.id }) {
                sites[index] = site
            } else {
                sites.append(site)
            }
            changePreview = try model.makeSiteChangePreview(sites: sites)
            editingSite = nil
        } catch {
            editorError = error.localizedDescription
        }
    }

    private func tlsTitle(_ site: ReverseProxySite) -> String {
        switch site.tlsMode {
        case .httpOnly: L10n.text("HTTP only")
        case .automaticHTTPS: L10n.text("Automatic HTTPS")
        case .dnsPodDNS01: L10n.text("DNSPod DNS-01")
        }
    }
}

private struct SiteEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var site: ReverseProxySite
    let isNewSite: Bool
    let dnsPodAvailable: Bool
    let existingSites: [ReverseProxySite]
    let onSave: (ReverseProxySite) -> Void
    @State private var validationError: String?
    @State private var isConfirmingPlaintext = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "network")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
                Text(isNewSite ? L10n.text("Add Site…") : L10n.text("Edit"))
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(20)
            Divider()
            Form {
                Section("Site") {
                    TextField("Hostname", text: $site.hostname)
                        .textFieldStyle(.roundedBorder)
                    TextField("Optional port", text: $site.port)
                        .textFieldStyle(.roundedBorder)
                    TextField("Upstream URL or host:port", text: $site.upstream)
                        .textFieldStyle(.roundedBorder)
                    Text("Use an HTTP or HTTPS upstream, such as `http://127.0.0.1:3000`.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("TLS") {
                    Picker("Certificate mode", selection: $site.tlsMode) {
                        Text("HTTP only").tag(SiteTLSMode.httpOnly)
                        Text("Automatic HTTPS").tag(SiteTLSMode.automaticHTTPS)
                        Text("DNSPod DNS-01").tag(SiteTLSMode.dnsPodDNS01)
                            .disabled(!dnsPodAvailable)
                    }
                    .onChange(of: site.tlsMode) { _, mode in
                        if mode == .httpOnly { site.acmeEnvironment = .production }
                    }

                    if site.tlsMode != .httpOnly {
                        Picker("ACME environment", selection: $site.acmeEnvironment) {
                            Text("Let's Encrypt production").tag(ACMEEnvironment.production)
                            Text("Let's Encrypt staging").tag(ACMEEnvironment.staging)
                        }
                        if site.acmeEnvironment == .staging {
                            Label("Staging certificates are intentionally not trusted by browsers.", systemImage: "testtube.2")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if site.tlsMode == .dnsPodDNS01 {
                        if dnsPodAvailable {
                            Picker("DNSPod credential", selection: $site.credentialMode) {
                                Text("Keychain environment variable").tag(DNSPodCredentialMode.keychain)
                                Text("Plain text in Caddyfile").tag(DNSPodCredentialMode.plainText)
                            }
                            if site.credentialMode == .keychain {
                                Text("The Caddyfile stores `{env.DNSPOD_TOKEN}`. Save the token in DNSPod settings; Caddyman injects it only into its child Caddy process.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                SecureField("APP_ID,APP_TOKEN", text: $site.plainTextToken)
                                    .textFieldStyle(.roundedBorder)
                                Label("The token will be written in plain text to the Caddyfile. Anyone who can read that file can use it.", systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        } else {
                            Label("The selected Caddy binary must contain dns.providers.dnspod before DNSPod can be used.", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                if let validationError {
                    Label(validationError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            Divider()
            HStack {
                Label("No changes are written until you validate and confirm.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Review Changes…") { validateAndSave() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(site.tlsMode == .dnsPodDNS01 && !dnsPodAvailable)
            }
            .padding(18)
        }
        .frame(width: 620, height: 570)
        .confirmationDialog(
            "Store this DNSPod token in plain text?",
            isPresented: $isConfirmingPlaintext,
            titleVisibility: .visible
        ) {
            Button("Continue to Diff Review", role: .destructive) {
                onSave(site)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The complete diff will show a redacted token, but the chosen Caddyfile will contain the real token in plain text.")
        }
    }

    private func validateAndSave() {
        do {
            try ReverseProxySiteValidator.validate(site, existingSites: existingSites)
            if site.tlsMode == .dnsPodDNS01 && site.credentialMode == .plainText {
                isConfirmingPlaintext = true
            } else {
                onSave(site)
            }
        } catch {
            validationError = error.localizedDescription
        }
    }
}

private struct CaddyfileBlockEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let block: CaddyfileSiteBlock
    let onReview: (String) -> Void
    @State private var source: String

    init(block: CaddyfileSiteBlock, onReview: @escaping (String) -> Void) {
        self.block = block
        self.onReview = onReview
        _source = State(initialValue: block.redactedSourceText)
    }

    private var containsHiddenCredentials: Bool {
        block.redactedSourceText != block.sourceText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(block.address, systemImage: "curlybraces")
                .font(.title2.weight(.semibold))
            Text("Edit this site block using Caddyfile syntax. Other parts of the file stay untouched.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $source)
                .font(.system(.callout, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
                }
                .disabled(containsHiddenCredentials)

            if containsHiddenCredentials {
                Label("This block contains a credential. Caddyman hides it and disables raw editing.",
                      systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Label("Changes are previewed as a complete diff and validated with the selected Caddy binary.",
                      systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Review Changes…") {
                    onReview(source)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(containsHiddenCredentials || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 720, height: 560)
    }
}

private struct SiteSectionLabel: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SiteEmptyState: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let symbol: String

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 23, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 118)
    }
}

private struct ImportEditorRequest: Identifiable {
    let id = UUID()
    let directive: CaddyfileImportDirective?
}

private struct CaddyfileImportEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var path: String
    @State private var isChoosingFile = false
    @State private var pickerError: String?
    let importingCaddyfileURL: URL
    let onSave: (String) -> Void

    init(initialPath: String, importingCaddyfileURL: URL, onSave: @escaping (String) -> Void) {
        _path = State(initialValue: initialPath)
        self.importingCaddyfileURL = importingCaddyfileURL
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Import a Caddyfile", systemImage: "doc.badge.arrow.up")
                .font(.title2.weight(.semibold))
            Text("Choose a file, or enter a relative path or glob pattern. Imported sites are shown read-only.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Choose File…", systemImage: "folder") { isChoosingFile = true }
                .buttonStyle(.bordered)
            TextField("sites/*.caddy", text: $path)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit { save() }
            Text("Relative paths are based on the selected Caddyfile’s folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let pickerError {
                Label(pickerError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Review Import…", systemImage: "doc.text.magnifyingglass") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 520)
        .fileImporter(
            isPresented: $isChoosingFile,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let selectedURL = urls.first else { return }
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: selectedURL.path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    pickerError = L10n.text("Choose a Caddyfile, not a folder.")
                    return
                }
                guard selectedURL.standardizedFileURL != importingCaddyfileURL.standardizedFileURL else {
                    pickerError = L10n.text("A Caddyfile cannot import itself.")
                    return
                }
                path = CaddyfileImportDirective.relativeReference(
                    to: selectedURL,
                    from: importingCaddyfileURL
                )
                pickerError = nil
            case .failure(let error):
                let nsError = error as NSError
                if nsError.domain != NSCocoaErrorDomain || nsError.code != 3072 {
                    pickerError = error.localizedDescription
                }
            }
        }
    }

    private func save() {
        onSave(path)
    }
}

private struct SiteChangeReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isValidating = false
    @State private var isApplying = false
    @State private var isConfirmingApply = false
    @State private var validationResult: CaddyCandidateValidationResult?
    @State private var applyResult: CaddyfileMigrationApplyResult?

    let preview: CaddyfileSiteChangePreview
    let validate: (Data, URL) async -> CaddyCandidateValidationResult
    let apply: (CaddyfileSiteChangePreview) async -> CaddyfileMigrationApplyResult

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Review Caddyfile changes", systemImage: "doc.text.magnifyingglass")
                .font(.title2.weight(.semibold))
            LabeledContent("Target Caddyfile", value: preview.targetURL.path)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Text(L10n.format("Managed sites: %d", preview.sites.count))
                .font(.callout.weight(.medium))
            Text("Complete proposed diff")
                .font(.headline)
            ScrollView([.horizontal, .vertical]) {
                Text(preview.diffText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
            }
            .caddymanDiffSurface()

            if let validationResult {
                Label(validationResult.detail, systemImage: validationResult.isValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(validationResult.isValid ? .green : .orange)
                    .textSelection(.enabled)
            }
            if let applyResult {
                Label(applyResult.detail, systemImage: applyResult.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(applyResult.succeeded ? .green : .orange)
                    .textSelection(.enabled)
            }

            HStack {
                Label("No changes are written until you validate and confirm.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Validate with selected Caddy", systemImage: "checkmark.shield") {
                    Task {
                        isValidating = true
                        let hasScopedAccess = preview.targetURL.startAccessingSecurityScopedResource()
                        defer { if hasScopedAccess { preview.targetURL.stopAccessingSecurityScopedResource() } }
                        validationResult = await validate(preview.candidateData, preview.targetURL.deletingLastPathComponent())
                        isValidating = false
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isValidating || isApplying)
                if isValidating || isApplying { ProgressView().controlSize(.small) }
                if validationResult?.isValid == true, applyResult?.succeeded != true {
                    Button("Back Up and Apply…", systemImage: "externaldrive.badge.timemachine") {
                        isConfirmingApply = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isValidating || isApplying)
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 580)
        .confirmationDialog("Apply site changes?", isPresented: $isConfirmingApply, titleVisibility: .visible) {
            Button("Back Up and Apply", role: .destructive) {
                Task {
                    isApplying = true
                    let hasScopedAccess = preview.targetURL.startAccessingSecurityScopedResource()
                    defer { if hasScopedAccess { preview.targetURL.stopAccessingSecurityScopedResource() } }
                    applyResult = await apply(preview)
                    isApplying = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Caddyman will validate again, create a protected backup, atomically update the target file, and reload only the Caddy process it started. If reload fails, it will restore the previous file and try to reload it.")
        }
    }
}
