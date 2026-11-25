import AppKit
import Darwin
import SwiftUI

@main
@MainActor
enum BKQuickRunApp {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.count == 3, arguments[1] == "--terminal-run" {
            ScriptRunFiles(directory: URL(fileURLWithPath: arguments[2], isDirectory: true)).runInTerminal()
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let lockDescriptor: Int32
        do {
            guard let descriptor = try InstanceLock.acquire(in: ScriptLibrary.configurationDirectory) else { return }
            lockDescriptor = descriptor
        } catch {
            app.activate()
            let alert = NSAlert(error: AppError("无法启动 BKQuickRun（\(error.localizedDescription)）。"))
            alert.runModal()
            return
        }
        defer { Darwin.close(lockDescriptor) }

        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

enum InstanceLock {
    static func acquire(in directory: URL) throws -> Int32? {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "instance.lock", directoryHint: .notDirectory)
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            if code == EWOULDBLOCK { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        // Keep the file in place so all processes lock the same inode.
        return descriptor
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let library = ScriptLibrary()
    private let scriptRuns = ScriptRuns()
    private let presentation = PanelPresentation()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusItem = statusItem
        guard let button = statusItem.button else { return }
        let icon = NSImage(named: "MenuBarIcon")
        icon?.accessibilityDescription = "BKQuickRun"
        button.image = icon ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: "BKQuickRun")
        button.toolTip = "BKQuickRun"
        button.target = self
        button.action = #selector(togglePanel)
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = false
        let hostingController = NSHostingController(rootView: PanelView(
            library: library,
            scriptRuns: scriptRuns,
            presentation: presentation,
            chooseScript: { [weak self] in self?.chooseScript() },
            closePanel: { [weak self] in self?.popover.performClose(nil) },
            resizePanel: { [weak self] in self?.resizePanel(toHeight: $0) }
        ))
        hostingController.sizingOptions = []
        popover.contentViewController = hostingController
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard scriptRuns.hasActiveRuns else { return .terminateNow }
        scriptRuns.stopAll {
            RunLoop.main.perform(inModes: [.common, .modalPanel]) {
                MainActor.assumeIsolated { sender.reply(toApplicationShouldTerminate: true) }
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        scriptRuns.removeOutputFiles()
    }

    @objc private func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard !popover.isShown, let button = statusItem?.button,
              let geometry = panelGeometry(for: button) else { return }
        NSApp.activate()
        popover.contentSize = fittedSize(in: geometry)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        guard let window = popover.contentViewController?.view.window else { return }
        window.acceptsMouseMovedEvents = true
        window.makeKey()
        DispatchQueue.main.async { [weak self] in self?.resizePanel() }
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        resizePanel()
    }

    func popoverDidClose(_ notification: Notification) {
        presentation.selection = nil
        presentation.route = .launcher
    }

    private func resizePanel(toHeight height: CGFloat? = nil) {
        guard popover.isShown, let button = statusItem?.button,
              let geometry = panelGeometry(for: button) else { return }
        let size = fittedSize(in: geometry, measuredHeight: height)
        guard popover.contentSize != size else { return }
        popover.contentSize = size
        // Refresh the anchor so AppKit positions the window and arrow together.
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func fittedSize(in geometry: PanelGeometry, measuredHeight: CGFloat? = nil) -> NSSize {
        let available = geometry.availableContentSize(preferredWidth: presentation.preferredWidth)
        let constraintsChanged = available != presentation.availableSize
        if constraintsChanged { presentation.availableSize = available }
        let hostingController = popover.contentViewController as? NSHostingController<PanelView>
        let height = (constraintsChanged ? nil : measuredHeight)
            ?? hostingController?.sizeThatFits(in: available).height ?? available.height
        return NSSize(width: available.width, height: min(available.height, max(1, ceil(height))))
    }

    private func panelGeometry(for button: NSStatusBarButton) -> PanelGeometry? {
        guard let anchorWindow = button.window else { return nil }
        let anchor = anchorWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let center = NSPoint(x: anchor.midX, y: anchor.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })
                ?? anchorWindow.screen ?? NSScreen.main else { return nil }
        return PanelGeometry(visibleFrame: screen.visibleFrame, anchorBottom: anchor.minY)
    }

    private func chooseScript() -> URL? {
        let previousBehavior = popover.behavior
        popover.behavior = .applicationDefined
        defer {
            popover.behavior = previousBehavior
            popover.contentViewController?.view.window?.makeKey()
        }

        let panel = NSOpenPanel()
        panel.title = "选择 Shell 脚本"
        panel.message = "请选择 .sh 文件。"
        panel.prompt = "选择"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.delegate = self
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct PanelGeometry {
    let visibleFrame: NSRect
    let anchorBottom: CGFloat

    func availableContentSize(preferredWidth: CGFloat) -> NSSize {
        // Leave space for the popover arrow and its outer frame.
        let clearance: CGFloat = 32
        let top = min(visibleFrame.maxY, anchorBottom)
        let usableHeight = min(visibleFrame.height * 0.75, top - visibleFrame.minY)
        return NSSize(width: min(preferredWidth, max(1, floor(visibleFrame.width - clearance))),
                      height: max(1, floor(usableHeight - clearance)))
    }

}

extension AppDelegate: NSOpenSavePanelDelegate {
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return true
        }
        return ScriptFile.isScriptPath(url.path)
    }
}
