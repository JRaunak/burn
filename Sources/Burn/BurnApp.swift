import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// Plain AppKit entry point. A SwiftUI App needs a scene, and an empty Settings scene opened a
/// blank window whenever the app was relaunched.
@main
enum BurnMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.mainMenu = editMenu()
        app.run()
    }
}

/// Never shown for an accessory app, but key equivalents still route through it, so without it
/// Cmd-C/V/W do nothing in the Settings and History windows.
private func editMenu() -> NSMenu {
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    edit.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    let menu = NSMenu()
    menu.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
    return menu
}

/// Owns the status item in AppKit. MenuBarExtra re-rendered its whole SwiftUI label on every
/// flicker frame (about 9% CPU); setting `button.image` directly is just an image swap.
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = AppModel()
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var subs: Set<AnyCancellable> = []
    private var monitors: [Any] = []
    /// An off-screen copy of the popover content at its natural height, used only for measuring.
    private var sizer: NSHostingView<AnyView>!
    /// The popover hangs off this instead of the status button. A popover re-anchors whenever it
    /// resizes, and over a fullscreen app the hidden menu bar slides the button offscreen, so the
    /// popover followed it. This stays where the button was when the popover opened.
    private let anchor: NSWindow = {
        let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = true
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return w
    }()

    func applicationDidFinishLaunching(_ note: Notification) {
        Windows.shared.model = model
        if let e = LoginItem.registerOnFirstLaunch() { model.report(e) }
        Updater.shared.start()
        // .transient treated a click on the status button as an outside click, so the button
        // reopened what it had just closed. Every close is triggered by hand instead.
        popover.behavior = .applicationDefined
        popover.delegate = self
        let content = { [unowned self] in
            PopoverView(close: { [weak self] in self?.popover.performClose(nil) }).environmentObject(model)
        }
        // Sized by hand from `sizer`, so SwiftUI's own resizing doesn't fight it.
        let hosting = NSHostingController(rootView: AnyView(content().frame(maxHeight: .infinity, alignment: .top)))
        hosting.sizingOptions = []
        sizer = NSHostingView(rootView: AnyView(content().fixedSize(horizontal: false, vertical: true)))
        popover.contentViewController = hosting
        model.objectWillChange
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] in self?.fit() }
            .store(in: &subs)

        guard let button = item.button else { return }
        button.image = FlameGlyph.idle
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(toggle)

        model.$today.combineLatest(model.$scanning)
            .map { today, scanning in scanning ? "Indexing…" : usd(today.cost) + (today.unpricedTokens > 0 ? "+" : "") }
            .removeDuplicates()
            .sink { button.attributedTitle = NSAttributedString(string: " " + $0, attributes: [
                .font: NSFont.menuBarFont(ofSize: 0), .foregroundColor: NSColor.labelColor]) }
            .store(in: &subs)
        let flame = model.flame
        flame.objectWillChange
            .receive(on: RunLoop.main)
            .sink { button.image = flame.image }
            .store(in: &subs)
    }

    @objc private func toggle() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.refresh()
            guard let buttonWindow = button.window, let home = buttonWindow.screen else { return }
            // Every display draws a replica of the item, but the button's window is on one of them,
            // so move its rect to the display that was clicked, the same distance from the right edge.
            let screen = screenUnderMouse() ?? home
            var rect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            let bar = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top)
            rect.origin.x = screen.frame.maxX - (home.frame.maxX - rect.minX)
            rect.origin.y = screen.frame.maxY - bar
            rect.size.height = bar
            anchor.setFrame(rect, display: false)
            anchor.orderFront(nil)
            popover.contentSize = sizer.fittingSize
            popover.show(relativeTo: anchor.contentView!.bounds, of: anchor.contentView!, preferredEdge: .minY)
            button.highlight(true)
            // Otherwise the popover can't take Esc while another app is active.
            NSApp.activate()
            popover.contentViewController?.view.window?.makeKey()
            watchForClose()
        }
    }

    private func watchForClose() {
        let close = { [weak self] in self?.popover.performClose(nil) }
        monitors = [
            // Activation is only a request since macOS 14, so Burn can stay inactive and its own
            // popover and status-button clicks arrive here too. The button's action handles those.
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                guard let self else { return }
                let ours = [self.popover.contentViewController?.view.window?.frame, self.anchor.frame,
                            self.item.button.flatMap { b in b.window?.convertToScreen(b.convert(b.bounds, to: nil)) }]
                if !ours.contains(where: { $0?.contains(NSEvent.mouseLocation) == true }) { close() }
            },
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] e in
                guard let self, let w = e.window else { return e }
                if e.type == .keyDown {
                    guard e.keyCode == 53, w === self.popover.contentViewController?.view.window else { return e }
                    close()
                    return nil
                }
                if Windows.shared.owns(w) { close() }
                return e
            },
        ].compactMap { $0 }
    }

    private func fit() {
        guard popover.isShown else { return }
        let size = sizer.fittingSize
        if abs(size.height - popover.contentSize.height) > 0.5 { popover.contentSize = size }
    }

    func popoverDidClose(_ notification: Notification) {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        anchor.orderOut(nil)
        item.button?.highlight(false)
        // Hand focus back to the app the user was in, unless they moved on to a Burn window.
        if NSApp.isActive && !Windows.shared.anyVisible { NSApp.hide(nil) }
    }
}

/// History and Settings are plain NSWindows, because SwiftUI's openWindow needs a scene and the
/// status item lives outside one.
final class Windows: NSObject, NSWindowDelegate {
    static let shared = Windows()
    var model: AppModel!
    private var open: [String: NSWindow] = [:]
    private var history: HistoryModel?

    func showHistory(_ filter: Filter) {
        show("history")
        history?.filter = filter
    }

    func show(_ id: String) {
        NSApp.activate()
        // The screen the user clicked the menu-bar item on; the mouse is still there.
        let screen = screenUnderMouse() ?? NSScreen.main
        if let w = open[id] {
            if w.screen != screen { place(w, on: screen) }
            w.makeKeyAndOrderFront(nil)
            return
        }
        let title: String, view: AnyView
        if id == "history" {
            let h = HistoryModel()
            history = h
            (title, view) = ("Burn History", AnyView(HistoryView(h: h).environmentObject(model)))
        } else {
            (title, view) = ("Burn Settings", AnyView(SettingsView().environmentObject(model)))
        }
        let hosting = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: hosting)
        // The window starts at 1x32 and SwiftUI sizes it later, so size it before centring.
        w.setContentSize(hosting.view.fittingSize)
        w.title = title
        w.isReleasedWhenClosed = false
        // Follow the user to the current Space instead of switching back to the window's old one.
        w.collectionBehavior.insert(.moveToActiveSpace)
        w.delegate = self
        place(w, on: screen)
        w.makeKeyAndOrderFront(nil)
        // Otherwise Settings' first amount field takes focus and shows its accent-coloured selection.
        w.makeFirstResponder(nil)
        open[id] = w
    }

    func owns(_ w: NSWindow) -> Bool { open.values.contains(w) }
    var anyVisible: Bool { open.values.contains { $0.isVisible } }

    private func place(_ w: NSWindow, on screen: NSScreen?) {
        guard let area = screen?.visibleFrame else { return w.center() }
        let size = w.frame.size
        let x = max(min(area.midX - size.width / 2, area.maxX - size.width), area.minX)
        let y = min(max(area.midY - size.height / 2, area.minY), area.maxY - size.height)
        w.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Closing discards the window, so filters and other view state start fresh next time.
    func windowWillClose(_ note: Notification) {
        guard let w = note.object as? NSWindow else { return }
        // Commits an amount being edited now, not when the next window takes the shared field editor.
        w.makeFirstResponder(nil)
        if open["history"] === w { history = nil }
        open = open.filter { $0.value !== w }
    }
}

enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Errors are reported rather than thrown: a managed Mac can block login items by policy.
    @discardableResult
    static func set(_ on: Bool) -> String? {
        do {
            try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            guard on, SMAppService.mainApp.status == .requiresApproval else { return nil }
            SMAppService.openSystemSettingsLoginItems()
            return "Allow Burn in System Settings > General > Login Items."
        } catch {
            return "Login item: \(error.localizedDescription)"
        }
    }

    /// A dev build in build/ never becomes the login item or gets replaced by an update.
    static var installed: Bool {
        ["/Applications/", NSHomeDirectory() + "/Applications/"].contains { Bundle.main.bundlePath.hasPrefix($0) }
    }

    static func registerOnFirstLaunch() -> String? {
        guard installed, !UserDefaults.standard.bool(forKey: "loginItem.asked") else { return nil }
        UserDefaults.standard.set(true, forKey: "loginItem.asked")
        return set(true)
    }
}

func screenUnderMouse() -> NSScreen? {
    NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
}

func usd(_ v: Double) -> String {
    v.formatted(.currency(code: "USD").precision(.fractionLength(v >= 1000 ? 0 : 2)))
}

func tokens(_ n: Int) -> String {
    switch n {
    // From here "%.0fk" would round up to "1000k".
    case 999_500...: return String(format: "%.1fM", Double(n) / 1e6)
    case 1_000...: return String(format: "%.0fk", Double(n) / 1e3)
    default: return "\(n)"
    }
}
