import AppKit
import SwiftUI

@MainActor
enum AppWindowPresenter {
    enum Target: Equatable { case settings }

    /// Avoid switching back to accessory mode while SwiftUI is creating the target window.
    private static var suppressAccessoryUntil: Date?
    private static var hideAccessoryWorkItem: DispatchWorkItem?
    private static var pendingTarget: Target?

    static func present(open: @escaping () -> Void, target: Target) {
        beginPresentation(target: target)
        open()
        dismissMenuBarExtra()
        focus(target: target, attempt: 0)
    }

    static func handleDidBecomeActive() {
        guard let pendingTarget,
              let window = findWindow(for: pendingTarget, includeHidden: true) else { return }
        bringToFront(window)
        self.pendingTarget = nil
    }

    static func hideDockIconIfNoWindows(excluding closingWindow: NSWindow? = nil) {
        if let closingWindow, isMenuBarPanel(closingWindow) { return }

        hideAccessoryWorkItem?.cancel()
        let work = DispatchWorkItem {
            if let until = suppressAccessoryUntil, Date() < until { return }

            let anotherWindowIsVisible = NSApp.windows.contains { window in
                guard window !== closingWindow else { return false }
                guard window.canBecomeKey, !isMenuBarPanel(window) else { return false }
                return window.isVisible || window.isMiniaturized
            }
            guard !anotherWindowIsVisible else { return }
            pendingTarget = nil
            NSApp.setActivationPolicy(.accessory)
        }
        hideAccessoryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    static func isMenuBarPanel(_ window: NSWindow) -> Bool {
        let className = String(describing: type(of: window))
        return className.localizedCaseInsensitiveContains("Popover")
            || className.localizedCaseInsensitiveContains("StatusBar")
            || className.localizedCaseInsensitiveContains("MenuBarExtra")
            || className.localizedCaseInsensitiveContains("NSStatusItem")
            || window.level == .popUpMenu
            || window.level == .statusBar
    }

    private static func beginPresentation(target: Target) {
        pendingTarget = target
        suppressAccessoryUntil = Date().addingTimeInterval(1.5)
        hideAccessoryWorkItem?.cancel()
        NSApp.setActivationPolicy(.regular)
        CaddymanAppDelegate.restoreBundleIconInDock()
        NSApp.activate()
    }

    private static func dismissMenuBarExtra() {
        for window in NSApp.windows where isMenuBarPanel(window) {
            window.orderOut(nil)
        }
    }

    private static func bringToFront(_ window: NSWindow) {
        window.collectionBehavior.insert(.moveToActiveSpace)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate()
    }

    private static func focus(target: Target, attempt: Int) {
        let delays: [TimeInterval] = [0.0, 0.05, 0.12, 0.25, 0.45, 0.8]
        guard attempt < delays.count else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt]) {
            dismissMenuBarExtra()
            if let window = findWindow(for: target, includeHidden: true) {
                bringToFront(window)
                pendingTarget = nil
                return
            }
            focus(target: target, attempt: attempt + 1)
        }
    }

    private static func findWindow(for target: Target, includeHidden: Bool) -> NSWindow? {
        NSApp.windows.first { window in
            guard window.canBecomeKey, !isMenuBarPanel(window) else { return false }
            guard window.isVisible || window.isMiniaturized || includeHidden else { return false }
            return matches(target: target, window: window)
        }
    }

    private static func matches(target: Target, window: NSWindow) -> Bool {
        let identifier = window.identifier?.rawValue ?? ""
        return identifier.localizedCaseInsensitiveContains("settings")
            || window.title.localizedCaseInsensitiveCompare(L10n.text("Settings")) == .orderedSame
            || window.title.localizedCaseInsensitiveCompare(L10n.text("Caddy")) == .orderedSame
            || window.title.localizedCaseInsensitiveCompare(L10n.text("DNSPod")) == .orderedSame
    }
}
