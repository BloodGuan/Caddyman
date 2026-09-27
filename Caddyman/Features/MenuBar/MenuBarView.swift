import AppKit
import Observation
import SwiftUI

struct MenuBarView: View {
    @Bindable var model: CaddymanAppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusHeader
            Divider()
            actionRows
        }
        .frame(width: 320)
        .task {
            await model.refresh()
        }
    }

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 11) {
                Image(systemName: "server.rack")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(statusColor, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Caddyman")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text(serviceSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }

            if case .ready(let installation) = model.inspectionState {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Caddy")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(installation.version)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("DNSPod")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(installation.dnsPodStatus.title)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if case .loaded = model.caddyfileReadState {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Sites")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(String(model.totalCaddyfileSiteCount))
                                .font(.caption.weight(.medium))
                        }
                    }
                }
                .padding(11)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    private var actionRows: some View {
        VStack(alignment: .leading, spacing: 2) {
            MenuActionRow(title: "Overview", systemImage: "rectangle.grid.1x2") {
                model.selectedSettingsTab = .overview
                AppWindowPresenter.present(
                    open: { openSettings() },
                    target: .settings
                )
            }
            .keyboardShortcut("o", modifiers: [.command])

            MenuActionRow(title: "Refresh Detection", systemImage: "arrow.clockwise") {
                Task { await model.refresh() }
            }
            .disabled(model.isRefreshing)

            MenuActionRow(title: "Settings", systemImage: "gearshape") {
                model.selectedSettingsTab = .caddy
                AppWindowPresenter.present(open: { openSettings() }, target: .settings)
            }
            .keyboardShortcut(",", modifiers: [.command])

            Divider()
                .padding(.horizontal, 10)
                .padding(.vertical, 4)

            MenuActionRow(title: "Quit Caddyman", systemImage: "power") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: [.command])
        }
        .padding(.vertical, 6)
    }

    private var statusColor: Color {
        return switch model.menuBarStatus {
        case .running: .green
        case .ready: .yellow
        case .error: .red
        }
    }

    private var serviceSummary: String {
        if model.managedCaddyIsRunning {
            return L10n.text("Managed Caddy is running")
        }
        if case .adminPortResponding = model.serviceStatus {
            return L10n.text("Admin port occupied; ownership unknown")
        }
        return L10n.text("Managed Caddy is stopped")
    }
}

struct CaddymanMenuBarMark: View {
    let status: CaddymanMenuBarStatus
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(nsImage: renderedMark)
            .renderingMode(.original)
            .accessibilityHidden(true)
    }

    private var renderedMark: NSImage {
        let foreground = colorScheme == .dark ? Color.white : Color.black
        let mark = ZStack(alignment: .bottomLeading) {
            Image("CaddymanStatusMark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(foreground)

            Circle()
                .fill(statusColor)
                .frame(width: 4.5, height: 4.5)
                .overlay {
                    Circle().strokeBorder(foreground, lineWidth: 0.75)
                }
                .offset(x: 1, y: -1)
        }
        .frame(width: 18, height: 13)

        let renderer = ImageRenderer(content: mark)
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: 36, height: 26))
        image.isTemplate = false
        return image
    }

    private var statusColor: Color {
        switch status {
        case .running: .green
        case .ready: .yellow
        case .error: .red
        }
    }
}
