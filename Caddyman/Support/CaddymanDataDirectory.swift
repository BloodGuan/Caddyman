import AppKit
import Foundation
import SwiftUI

@MainActor
struct SettingsWindowTitleHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        SettingsTitleHidingView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? SettingsTitleHidingView)?.hideWindowTitle()
    }
}

@MainActor
private final class SettingsTitleHidingView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hideWindowTitle()
    }

    func hideWindowTitle() {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.title = ""
    }
}

@MainActor
protocol CaddymanDataDirectoryOpening {
    var directoryURL: URL { get }
    func createAndOpen() throws
}

@MainActor
struct SystemCaddymanDataDirectoryOpener: CaddymanDataDirectoryOpening {
    private let fileManager: FileManager
    private let workspace: NSWorkspace

    init(fileManager: FileManager = .default, workspace: NSWorkspace = .shared) {
        self.fileManager = fileManager
        self.workspace = workspace
    }

    var directoryURL: URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport.appendingPathComponent("Caddyman", isDirectory: true)
    }

    func createAndOpen() throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard workspace.open(directoryURL) else {
            throw CaddymanDataDirectoryError.couldNotOpen(directoryURL)
        }
    }
}

enum CaddymanDataDirectoryError: LocalizedError {
    case couldNotOpen(URL)

    var errorDescription: String? {
        switch self {
        case .couldNotOpen(let url):
            L10n.format("Could not open the folder in Finder: %@", url.path)
        }
    }
}
