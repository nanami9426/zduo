import AppKit
import SwiftUI
import Combine

@main
enum ZDuoMain {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.contains("--diagnose") {
            Diagnostics.sensor()
            return
        }
        if let index = arguments.firstIndex(of: "--render-check"), arguments.count > index + 1 {
            do { try Diagnostics.render(directory: URL(fileURLWithPath: arguments[index + 1])) }
            catch { fputs("Render check failed: \(error)\n", stderr); exit(1) }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var hotKey: GlobalHotKey?
    private var subscriptions: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildPanel()
        hotKey = GlobalHotKey { [weak self] in
            MainActor.assumeIsolated { self?.model.setEnabled(false) }
        }
        model.shortcutAvailable = hotKey?.isRegistered == true
        model.onStatusChange = { [weak self] in self?.updateStatusItem() }
        model.$rawAngle.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatusItem() }
        }.store(in: &subscriptions)
        model.$overlayVisible.removeDuplicates().sink { [weak self] visible in
            self?.panel.level = visible ? OverlayWindow.controlLevel : .floating
        }.store(in: &subscriptions)
        model.start()
        showPanel()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
        hotKey = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "ZDuo")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        let menu = NSMenu()
        let appMenu = NSMenuItem()
        let submenu = NSMenu()
        submenu.addItem(withTitle: "退出 ZDuo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.submenu = submenu
        menu.addItem(appMenu)
        NSApp.mainMenu = menu
    }

    private func buildPanel() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 680),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "ZDuo"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = NSColor(red: 0.067, green: 0.075, blue: 0.10, alpha: 1)
        panel.appearance = NSAppearance(named: .darkAqua)
        let view = ControlPanel(model: model) { [weak self] in self?.panel.orderOut(nil) }
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentView = hosting
        panel.center()
    }

    private func showPanel() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func updateStatusItem() {
        let angle = model.rawAngle.map { " \(Int($0))°" } ?? ""
        statusItem.button?.title = angle
        statusItem.button?.appearsDisabled = !model.enabled
        statusItem.button?.toolTip = "ZDuo · \(model.captureStatus)\n左键打开控制面板，右键停用或退出"
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.delegate = self
            let toggle = NSMenuItem(title: model.enabled ? "立即停用效果" : "启用景深效果", action: #selector(toggleEffect), keyEquivalent: "")
            toggle.target = self
            menu.addItem(toggle)
            let controls = NSMenuItem(title: "打开控制面板", action: #selector(openControls), keyEquivalent: "")
            controls.target = self
            menu.addItem(controls)
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出 ZDuo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else if panel.isVisible {
            panel.orderOut(nil)
        } else { showPanel() }
    }

    @objc private func toggleEffect() { model.setEnabled(!model.enabled) }
    @objc private func openControls() { showPanel() }
    func menuWillOpen(_ menu: NSMenu) { model.setMenuOpen(true) }
    func menuDidClose(_ menu: NSMenu) { model.setMenuOpen(false) }
}
