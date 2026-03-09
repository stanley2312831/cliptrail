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
                .textSelection(.enabled)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { onCopy() }
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
        .frame(minWidth: 620, minHeight: 480)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let root = ContentView(model: model)
        let hosting = NSHostingController(rootView: root)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "ClipTrail"
        window.contentViewController = hosting
        window.makeKeyAndOrderFront(nil)

        self.window = window
        model.startWatching()
        setupStatusBar()
        setupHotkeyMonitor()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "📋"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "打开 ClipTrail", action: #selector(showWindow), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "刷新历史", action: #selector(refreshHistory), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))

        menu.items.forEach { $0.target = self }
        statusItem?.menu = menu
    }

    private func setupHotkeyMonitor() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self = self else { return }
            let isOptionV = event.modifierFlags.contains(.option) && event.keyCode == UInt16(kVK_ANSI_V)
            if isOptionV { self.toggleWindow() }
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let isOptionV = event.modifierFlags.contains(.option) && event.keyCode == UInt16(kVK_ANSI_V)
            if isOptionV {
                self.toggleWindow()
                return nil
            }
            return event
        }
    }

    @objc private func showWindow() {
        guard let window = window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func refreshHistory() {
        model.refresh()
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

    func applicationWillTerminate(_ notification: Notification) {
        model.stopWatching()
        if let g = globalMonitor { NSEvent.removeMonitor(g) }
        if let l = localMonitor { NSEvent.removeMonitor(l) }
    }
}

func runGUI() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.setActivationPolicy(.regular)
    app.delegate = delegate
    app.run()
}

// Keep CLI entry simple for users.
let args = Array(CommandLine.arguments.dropFirst())
if args.first == "gui" || args.isEmpty {
    runGUI()
} else {
    print("ClipTrail 现在主打 GUI。请直接运行: cliptrail gui")
}
