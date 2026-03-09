import Foundation
import AppKit

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
  cliptrail list [--limit 30]
  cliptrail copy --index <n>
  cliptrail clear
  cliptrail status

Tips:
  - Keep watch running in background (or use launchd plist from scripts/)
  - Use `cliptrail copy --index 0` to put latest history item back to clipboard
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

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else {
    usage(); exit(0)
}

switch cmd {
case "watch":
    let interval = parseDouble(args, "--interval", default: 0.8)
    let maxItems = parseInt(args, "--max-items", default: 500)
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
