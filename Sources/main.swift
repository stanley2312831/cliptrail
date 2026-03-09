import Foundation
import AppKit
import SwiftUI

struct ClipItem: Codable {
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
        var items = load()
        if items.first?.text == text { return }
        items.insert(ClipItem(text: text, timestamp: Date()), at: 0)
        if items.count > maxItems { items = Array(items.prefix(maxItems)) }
        save(items)
    }

    func clear() {
        save([])
    }
}

func usage() {
    print("""
ClipTrail - macOS clipboard history

Usage:
  cliptrail watch [--interval 0.8] [--max-items 500]
  cliptrail gui
  cliptrail list [--limit 30]
  cliptrail copy --index <n>
  cliptrail clear
  cliptrail status

Tips:
  - Keep watch running in background (or use launchd plist from scripts/)
  - Use `cliptrail copy --index 0` to put latest history item back to clipboard
  - Use `cliptrail gui` for desktop window mode
  - In GUI mode, press Option+V globally to show/hide the window
""")
}

func parseDouble(_ args: [String], _ flag: String, default value: Double) -> Double {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count, let v = Double(args[i + 1]) else { return value }
    return v
}

func parseInt(_ args: [String], _ flag: String, default value: Int) -> Int {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count, let v = Int(args[i + 1]) else { return value }
    return v
}

func runWatcher(interval: Double, maxItems: Int) {
    let store = Store(maxItems: maxItems)
    let pb = NSPasteboard.general
    var changeCount = pb.changeCount
    print("ClipTrail watcher started (interval: \(interval)s, max: \(maxItems))")

    while true {
        if pb.changeCount != changeCount {
            changeCount = pb.changeCount
            if let text = pb.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                store.append(text)
                print("+ captured: \(text.prefix(60))")
            }
        }
        Thread.sleep(forTimeInterval: interval)
    }
}

final class ClipboardModel: ObservableObject {
    @Published var items: [ClipItem] = []

    private let store = Store(maxItems: 500)
    private let pb = NSPasteboard.general
    private var timer: Timer?
    private var changeCount: Int

    init() {
        self.changeCount = pb.changeCount
        refresh()
    }

    func startWatching() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
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

    func copyBack(index: Int) {
        guard index >= 0, index < items.count else { return }
        pb.clearContents()
        pb.setString(items[index].text, forType: .string)
    }

    private func pollClipboard() {
        if pb.changeCount != changeCount {
            changeCount = pb.changeCount
            if let text = pb.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                store.append(text)
                refresh()
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: ClipboardModel

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("ClipTrail")
                    .font(.title2).bold()
                Spacer()
                Button("Refresh") { model.refresh() }
                Button("Clear") { model.clear() }
            }

            List(Array(model.items.enumerated()), id: \.offset) { (idx, item) in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("#\(idx)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Copy Back") { model.copyBack(index: idx) }
                            .buttonStyle(.bordered)
                    }
                    Text(item.text)
                        .font(.body)
                        .lineLimit(3)
                    Text(item.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(14)
        .frame(minWidth: 700, minHeight: 460)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    let model = ClipboardModel()
    private var globalMonitor: Any?
    private var localMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let root = ContentView(model: model)
        let hosting = NSHostingController(rootView: root)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "ClipTrail GUI"
        window.contentViewController = hosting
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        model.startWatching()
        setupHotkeyMonitor()
    }

    private func setupHotkeyMonitor() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self = self else { return }
            let isOptionV = event.modifierFlags.contains(.option) && event.charactersIgnoringModifiers?.lowercased() == "v"
            if isOptionV {
                self.toggleWindow()
            }
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let isOptionV = event.modifierFlags.contains(.option) && event.charactersIgnoringModifiers?.lowercased() == "v"
            if isOptionV {
                self.toggleWindow()
                return nil
            }
            return event
        }
    }

    private func toggleWindow() {
        guard let window = window else { return }
        if window.isVisible {
            window.orderOut(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
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

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else {
    usage(); exit(0)
}

switch cmd {
case "watch":
    runWatcher(interval: parseDouble(args, "--interval", default: 0.8), maxItems: parseInt(args, "--max-items", default: 500))

case "gui":
    runGUI()

case "list":
    let limit = parseInt(args, "--limit", default: 30)
    let store = Store(maxItems: 500)
    let items = Array(store.load().prefix(limit))
    if items.isEmpty {
        print("(empty)")
    } else {
        let df = ISO8601DateFormatter()
        for (i, it) in items.enumerated() {
            let oneLine = it.text.replacingOccurrences(of: "\n", with: " ")
            print("[\(i)] \(df.string(from: it.timestamp))  \(oneLine.prefix(120))")
        }
    }

case "copy":
    guard let i = args.firstIndex(of: "--index"), i + 1 < args.count, let idx = Int(args[i + 1]) else {
        print("Missing --index <n>"); exit(1)
    }
    let store = Store(maxItems: 500)
    let items = store.load()
    guard idx >= 0 && idx < items.count else {
        print("Index out of range. Current items: \(items.count)"); exit(1)
    }
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(items[idx].text, forType: .string)
    print("Copied history[\(idx)] back to clipboard")

case "clear":
    Store(maxItems: 500).clear()
    print("Clipboard history cleared")

case "status":
    let store = Store(maxItems: 500)
    let count = store.load().count
    print("History file: \(store.fileURL.path)")
    print("Items: \(count)")

default:
    usage()
}
