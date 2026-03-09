import Foundation
import AppKit
import SwiftUI
import ServiceManagement
import Carbon.HIToolbox

struct ClipItem: Codable, Hashable {
    let text: String
    let timestamp: Date
}

struct Store {
    let fileURL: URL
    let maxItems: Int

    init(maxItems: Int) {
        self.maxItems = maxItems
        let fm = FileManager.default
        let appSupport = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClipTrail", isDirectory: true)
        try? fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        self.fileURL = appSupport.appendingPathComponent("history.json")
    }

    func load() -> [ClipItem] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([ClipItem].self, from: data)) ?? []
    }

    func save(_ items: [ClipItem]) {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: fileURL)
        }
    }

    func append(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        var items = load()
        if items.first?.text == clean { return }
        items.insert(ClipItem(text: clean, timestamp: Date()), at: 0)
        if items.count > maxItems { items = Array(items.prefix(maxItems)) }
        save(items)
    }

    func clear() {
        save([])
    }
}

final class AppModel: ObservableObject {
    @Published var items: [ClipItem] = []
    @Published var query: String = ""
    @Published var launchAtLogin: Bool = false
    @Published var toastMessage: String?

    private let store = Store(maxItems: 800)
    private let pb = NSPasteboard.general
    private var timer: Timer?
    private var changeCount: Int
    private var suppressNextOwnedCopyText: String?

    init() {
        self.changeCount = pb.changeCount
        self.launchAtLogin = UserDefaults.standard.bool(forKey: "launchAtLogin")
        refresh()
    }

    var filteredItems: [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return items }
        return items.filter { $0.text.lowercased().contains(q) }
    }

    func startWatching() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.pollClipboard()
        }
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        items = store.load()
    }

    func clear() {
        store.clear()
        refresh()
    }

    func copyBack(_ item: ClipItem) {
        suppressNextOwnedCopyText = item.text
        pb.clearContents()
        pb.setString(item.text, forType: .string)
        showToast("已复制到剪贴板")
    }

    func toggleLaunchAtLogin(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "launchAtLogin")
        launchAtLogin = enabled

        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("LaunchAtLogin update failed: \(error)")
            }
        }
    }

    private func showToast(_ text: String) {
        toastMessage = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.toastMessage == text {
                self?.toastMessage = nil
            }
        }
    }

    private func pollClipboard() {
        if pb.changeCount != changeCount {
            changeCount = pb.changeCount
            if let text = pb.string(forType: .string) {
                if let owned = suppressNextOwnedCopyText, owned == text {
                    suppressNextOwnedCopyText = nil
                    return
                }
                store.append(text)
                refresh()
            }
        }
    }
}

struct RowView: View {
    let item: ClipItem
    let onCopy: () -> Void

    var body: some View {
        Button(action: onCopy) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(item.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("点击即复制")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(item.text)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("ClipTrail")
                    .font(.title2).bold()
                Spacer()
                Toggle("开机自启", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.toggleLaunchAtLogin($0) }
                ))
                .toggleStyle(.switch)
                .frame(width: 130)
                Button("清空") { model.clear() }
                Button("刷新") { model.refresh() }
            }

            TextField("搜索剪贴板历史...", text: $model.query)
                .textFieldStyle(.roundedBorder)

            if model.filteredItems.isEmpty {
                Spacer()
                Text("暂无记录")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(model.filteredItems, id: \.self) { item in
                    RowView(item: item) {
                        model.copyBack(item)
                    }
                }
                .listStyle(.inset)
            }

            HStack {
                Text("快捷键：Option + V 呼出/隐藏")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("若无效，请在 系统设置→隐私与安全性→辅助功能 中允许 ClipTrail")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("点击任意历史项即可回填")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(minWidth: 500, minHeight: 380)
        .overlay(alignment: .bottom) {
            if let toast = model.toastMessage {
                Text(toast)
                    .font(.subheadline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.toastMessage)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let root = ContentView(model: model)
        let hosting = NSHostingController(rootView: root)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "ClipTrail"
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .moveToActiveSpace]
        window.contentViewController = hosting
        window.makeKeyAndOrderFront(nil)

        self.window = window
        model.startWatching()
        setupStatusBar()
        setupHotkeyMonitor()
        showWindow()

        // Fallback: some systems defer first window presentation; force once more.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.showWindow()
        }
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "📋"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "打开 ClipTrail", action: #selector(showWindow), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "重置窗口位置", action: #selector(resetWindowPosition), keyEquivalent: "0"))
        menu.addItem(NSMenuItem(title: "刷新历史", action: #selector(refreshHistory), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))

        menu.items.forEach { $0.target = self }
        statusItem?.menu = menu
    }

    private func setupHotkeyMonitor() {
        // Local fallback (works when app is focused)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let isOptionV = event.modifierFlags.contains(.option) && event.keyCode == UInt16(kVK_ANSI_V)
            if isOptionV {
                self.toggleWindow()
                return nil
            }
            return event
        }

        // Global reliable registration via Carbon hotkey
        var hotKeyID = EventHotKeyID(signature: OSType(0x4354524C), id: 1) // 'CTRL'
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event = event, let userData = userData else { return noErr }
            var hkID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            if status == noErr, hkID.id == 1 {
                let app = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { app.toggleWindow() }
            }
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, selfPtr, &eventHandlerRef)
        RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(optionKey), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    @objc private func showWindow() {
        guard let window = window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKey()
    }

    @objc private func refreshHistory() {
        model.refresh()
    }

    @objc private func resetWindowPosition() {
        guard let window = window else { return }
        window.setFrame(NSRect(x: 0, y: 0, width: 560, height: 420), display: true)
        window.center()
        showWindow()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func toggleWindow() {
        guard let window = window else { return }
        if window.isVisible {
            window.orderOut(nil)
        } else {
            showWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopWatching()
        if let g = globalMonitor { NSEvent.removeMonitor(g) }
        if let l = localMonitor { NSEvent.removeMonitor(l) }
        if let hk = hotKeyRef { UnregisterEventHotKey(hk) }
        if let eh = eventHandlerRef { RemoveEventHandler(eh) }
    }
}

func runGUI() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.setActivationPolicy(.regular)
    app.delegate = delegate
    app.run()
}

// App launch note:
// Finder/Dock launches pass arguments like "-psn_0_12345".
// So we should default to GUI for any non-explicit debug arg.
let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--help" {
    print("ClipTrail GUI app. Launch directly from Applications or run: cliptrail gui")
} else {
    runGUI()
}
