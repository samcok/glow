import SwiftUI
import AppKit

/// One model for window and popover.
@MainActor enum Shared {
    static let hue = Hue()
    static let pairing = Pairing(hue: hue)
    static var openMain: () -> Void = {}
    static var openWindow: () -> Void = {}
}

@main
struct GlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("Glow", id: "main") {
            MainView(hue: Shared.hue).frame(minWidth: 720, minHeight: 680)
        }
    }
}

/// Menu-bar item: left click = popover, right click = menu.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var demoWindow: NSWindow?

    func applicationDidFinishLaunching(_ n: Notification) {
        if ProcessInfo.processInfo.environment["GLOW_SELFTEST"] == "1" { selfTest(); exit(0) }   // ./build.sh --test
        Shared.hue.start()
        if Shared.hue.demoSetup {   // GLOW_DEMO_SETUP: the Window scene doesn't open by itself here, so host the main view by hand
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 680), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.contentView = NSHostingView(rootView: MainView(hue: Shared.hue)); w.setFrameTopLeftPoint(NSPoint(x: 100, y: NSScreen.screens[0].frame.maxY - 100)); w.isReleasedWhenClosed = false; w.level = .floating
            demoWindow = w; NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil)
            FileHandle.standardError.write(Data("winid \(w.windowNumber)\n".utf8))   // for screencapture -l
            if ProcessInfo.processInfo.environment["GLOW_DEMO_SETUP_AUTO"] == "1" {   // headless test: click the fake bridge after 2.5 s
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { Shared.pairing.pair(host: "192.168.1.2", id: "demo") }
            }
        }
        popover.behavior = .transient
        let host = NSHostingController(rootView: PopoverView(hue: Shared.hue))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        Shared.openMain = { [weak self] in self?.openMain() }
        // Main window closed → leave the Dock, stay in the menu bar.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { n in
            guard let w = n.object as? NSWindow, w.styleMask.contains(.titled), w.canBecomeMain else { return }
            MainActor.assumeIsolated { _ = NSApp.setActivationPolicy(.accessory) }
        }
        if let b = item.button {
            let img = NSImage(systemSymbolName: "lightbulb.max", accessibilityDescription: "Glow")
            img?.isTemplate = true
            b.image = img
            b.target = self
            b.action = #selector(clicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    @objc private func clicked() {
        guard let b = item.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            let m = NSMenu()
            m.addItem(withTitle: String(localized: "Open Glow"), action: #selector(openMain), keyEquivalent: "").target = self
            if Shared.hue.cfg != nil {
                m.addItem(withTitle: String(localized: "Forget bridge"), action: #selector(forget), keyEquivalent: "").target = self
            }
            m.addItem(withTitle: String(localized: "Quit Glow"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            item.menu = m
            b.performClick(nil)
            item.menu = nil
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            if let w = popover.contentViewController?.view.window {
                // Without this the popover can't appear over another app's full-screen Space.
                w.collectionBehavior.formUnion([.fullScreenAuxiliary, .canJoinAllSpaces])
                w.makeKey()
            }
            Task { await Shared.hue.refresh() }
        }
    }

    @objc private func forget() { Shared.hue.forget() }

    @objc private func openMain() {
        popover.performClose(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.styleMask.contains(.titled) && $0.canBecomeMain }) {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else { Shared.openWindow() }
    }
}

struct Waiting: View {
    let hue: Hue
    var body: some View {
        VStack { ProgressView(); if let e = hue.error { Text(e).font(.caption).foregroundStyle(.red) } }.padding()
    }
}

struct MainView: View {
    let hue: Hue
    @StateObject private var sel = Box<String?>(nil)
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Gate(hue: hue) {
            let current = Binding(get: { sel.v ?? hue.rooms.first?.id }, set: { sel.v = $0 })
            let room = hue.rooms.first(where: { $0.id == current.wrappedValue })
            NavigationStack {
                Group {
                    if let r = room { RoomView(hue: hue, room: r).id(r.id) } else { Waiting(hue: hue) }
                }
                .background { RoomGlow(hue: hue, room: room) }
                // Room switcher in place of the title: a native menu button, scales to any number of rooms.
                .toolbar(removing: .title)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Menu {
                            Picker("Room", selection: current) {
                                ForEach(hue.rooms) { Text($0.metadata.name).tag(Optional($0.id)) }
                            }.pickerStyle(.inline).labelsHidden()
                        } label: {
                            Label(room?.metadata.name ?? "", systemImage: "house").font(.headline)
                        }.labelStyle(.titleAndIcon).fixedSize().accessibilityLabel("Room")
                    }
                }
            }
        }
        .onAppear { Shared.openWindow = { openWindow(id: "main") } }
    }
}

struct PopoverView: View {
    let hue: Hue
    @StateObject private var sel = Box<String?>(nil)

    var body: some View {
        let current = Binding(get: { sel.v ?? hue.rooms.first?.id }, set: { sel.v = $0 })
        let room = hue.rooms.first(where: { $0.id == current.wrappedValue })
        Group {
            Gate(hue: hue, compact: true) {
                VStack(spacing: 0) {
                    HStack {
                        Picker("Room", selection: current) {
                            ForEach(hue.rooms) { Text($0.metadata.name).tag(Optional($0.id)) }
                        }.pickerStyle(.menu).labelsHidden().fixedSize()
                        Spacer()
                        Button { Shared.openMain() } label: { Image(systemName: "macwindow") }
                            .buttonStyle(.glass).help("Open Glow").accessibilityLabel("Open Glow")
                    }.padding([.horizontal, .top], 16)
                    if let r = room { RoomView(hue: hue, room: r, compact: true).id(r.id) } else { Waiting(hue: hue) }
                }
            }
        }
        .background { RoomGlow(hue: hue, room: room).opacity(0.7) }
        .frame(width: 360)
    }
}
