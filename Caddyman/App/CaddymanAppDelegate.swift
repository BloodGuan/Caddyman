import AppKit

@MainActor
final class CaddymanAppDelegate: NSObject, NSApplicationDelegate {
    private var windowCloseObserver: NSObjectProtocol?
    private var terminationInProgress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Self.restoreBundleIconInDock()
        Task { await CaddymanLifecycle.model.applicationDidLaunch() }
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { notification in
            let closingWindow = notification.object as? NSWindow
            DispatchQueue.main.async {
                AppWindowPresenter.hideDockIconIfNoWindows(excluding: closingWindow)
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Self.restoreBundleIconInDock()
        AppWindowPresenter.handleDidBecomeActive()
    }

    static func restoreBundleIconInDock() {
        NSApp.applicationIconImage = nil
        NSApp.dockTile.display()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationInProgress else { return .terminateLater }
        terminationInProgress = true
        Task {
            let stopped = await CaddymanLifecycle.model.stopOwnedCaddyForTermination()
            terminationInProgress = false
            if !stopped {
                let alert = NSAlert()
                alert.messageText = L10n.text("Caddy could not be stopped")
                alert.informativeText = CaddymanLifecycle.model.runtimeActionMessage
                    ?? L10n.text("Caddyman stayed open so you can review the service status.")
                alert.alertStyle = .warning
                alert.runModal()
            }
            sender.reply(toApplicationShouldTerminate: stopped)
        }
        return .terminateLater
    }

    deinit {
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
        }
    }
}
