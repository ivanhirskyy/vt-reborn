import AppKit
import SwiftUI

final class StatusBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let model: AppModel

    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "clock.badge.checkmark",
                accessibilityDescription: "VT Puncher"
            )
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "VT Puncher"
        }

        popover.contentViewController = NSHostingController(
            rootView: ContentView().frame(width: 760, height: 520)
        )
        popover.behavior = .applicationDefined
        popover.delegate = self
        popover.contentSize = NSSize(width: 760, height: 520)
    }

    // MARK: - Toggle

    @objc private func handleClick(_ sender: Any?) {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    func openPopover() {
        showPopover()
    }

private func showPopover() {
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if let window = popover.contentViewController?.view.window {
            window.makeKeyAndOrderFront(nil)
        }
        installMonitors()
        Task { await model.refresh() }
    }

    private func closePopover() {
        removeMonitors()
        popover.performClose(nil)
    }

    // MARK: - Outside-click handling

    /// .applicationDefined popovers never close on their own, so we close them
    /// ourselves when the user clicks outside the popover (but not on the
    /// status item, which toggles it).
    private func installMonitors() {
        guard globalMonitor == nil else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            // Global monitor: locationInWindow is already in screen coordinates.
            self?.handleMouseDown(event.locationInWindow)
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Esc
                self?.closePopover()
            }
            return event
        }
    }

    private func handleMouseDown(_ screenPoint: NSPoint) {
        if isClickInsideAppWindows(screenPoint) { return }
        closePopover()
    }

    private func isClickInsideAppWindows(_ screenPoint: NSPoint) -> Bool {
        // Popover content (and any sheet attached to it, e.g. Settings).
        if let window = popover.contentViewController?.view.window {
            if window.frame.contains(screenPoint) { return true }
            for sheet in window.sheets where sheet.frame.contains(screenPoint) { return true }
        }
        // The status item itself — its button action toggles the popover.
        if let button = statusItem.button, let buttonWindow = button.window {
            let screenRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            if screenRect.contains(screenPoint) { return true }
        }
        return false
    }

    private func removeMonitors() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    // MARK: - Context menu

    private func showContextMenu() {
        guard let button = statusItem.button else { return }

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshAction), keyEquivalent: "r")
        refreshItem.target = self
        let quitItem = NSMenuItem(
            title: "Quit vt-reborn",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApplication.shared

        let menu = NSMenu()
        menu.addItem(refreshItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func refreshAction() {
        Task { await model.refresh() }
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        removeMonitors()
    }
}
