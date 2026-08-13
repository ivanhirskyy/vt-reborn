import AppKit
import SwiftUI

/// The regular app window shown when the Dock icon is clicked.
/// The menu-bar icon keeps using the popover instead.
final class MainWindowController {
    static let shared = MainWindowController()

    private var window: NSWindow?

    private init() {}

    func show() {
        if let window = window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        let host = NSHostingController(rootView: ContentView())
        let window = NSWindow(contentViewController: host)
        window.title = "VT Puncher"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 784, height: 540))
        window.center()
        window.minSize = NSSize(width: 700, height: 480)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        if AppSettings.shared.hasValidCredentials {
            Task { await AppModel.shared.refresh() }
        }
    }

    func close() {
        window?.performClose(nil)
    }
}
