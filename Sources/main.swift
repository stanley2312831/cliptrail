import Foundation
import AppKit
import SwiftUI
import Carbon.HIToolbox

enum ClipKind: String, Codable {
    case text
    case image
    case files
}

struct ClipItem: Codable, Hashable, Identifiable {
    let id: UUID
    let kind: ClipKind
    let text: String?
    let imagePath: String?
    let filePaths: [String]?
    let timestamp: Date
    var pinned: Bool

    var preview: String {
        switch kind {
        case .text:
            return text ?? ""
        case .image:
            return "[图片]"
        case .files:
            let count = filePaths?.count ?? 0
            return "[文件] \(count) 项"
        }
    }

    var kindLabel: String {
        switch kind {
        case .text: return "文本"
        case .image: return "图片"
        case .files: return "文件"
        }
    }
}

struct Store {
    let rootURL: URL
    let fileURL: URL
    let imagesDir: URL
    let maxItems: Int

    init(maxItems: Int = 1000) {
        self.maxItems = maxItems
        let fm = FileManager.default
        let appSupport = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClipTrail", isDirectory: true)
        try? fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        self.rootURL = appSupport
        self.fileURL = appSupport.appendingPathComponent("history.json")
        self.imagesDir = appSupport.appendingPathComponent("images", isDirectory: true)
        try? fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
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

    func imageFileURL(for id: UUID) -> URL {
        imagesDir.appendingPathComponent("\(id.uuidString).png")
    }

    func append(_ item: ClipItem) {
        var items = load()
        if let first = items.first, fingerprint(of: first) == fingerprint(of: item) { return }
        items.insert(item, at: 0)
        items = clamp(items)
        save(items)
    }

    func overwrite(_ items: [ClipItem]) {
        save(clamp(items))
    }

    func clamp(_ items: [ClipItem]) -> [ClipItem] {
        let pinned = items.filter { $0.pinned }
        let normal = items.filter { !$0.pinned }
        let allowNormal = max(0, maxItems - pinned.count)
        let limited = pinned + Array(normal.prefix(allowNormal))
        return limited.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned && !rhs.pinned }
            return lhs.timestamp > rhs.timestamp
        }
    }

    func clear() {
        save([])
        try? FileManager.default.removeItem(at: imagesDir)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
    }

    func fingerprint(of item: ClipItem) -> String {
        switch item.kind {
        case .text: return "t:\(item.text ?? "")"
        case .image: return "i:\(item.imagePath ?? "")"
        case .files: return "f:\((item.filePaths ?? []).joined(separator: "|"))"
        }
    }
}

struct UpdateInfo {
    let version: String
    let notes: String
    let dmgUrl: URL
    let releaseUrl: URL
}

final class AppModel: ObservableObject {
    @Published var items: [ClipItem] = []
    @Published var query: String = ""
    @Published var launchAtLogin: Bool = false
    @Published var toastMessage: String?
    @Published var updateInfo: UpdateInfo?
    @Published var checkingUpdate: Bool = false
    @Published var updatingNow: Bool = false
    @Published var selectedId: UUID?

    private let store = Store(maxItems: 1000)
    private let pb = NSPasteboard.general
    private var timer: Timer?
    private var changeCount: Int
    private var suppressNextOwnedFingerprint: String?

    init() {
        self.changeCount = pb.changeCount
        self.launchAtLogin = false
        self.launchAtLogin = detectLoginItemEnabled()
        refresh()
    }

    var filteredItems: [ClipItem] {
        let sorted = items.sorted {
            if $0.pinned != $1.pinned { return $0.pinned && !$1.pinned }
            return $0.timestamp > $1.timestamp
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return sorted }
        return sorted.filter { item in
            if item.kind == .text { return (item.text ?? "").lowercased().contains(q) }
            if item.kind == .files { return (item.filePaths ?? []).joined(separator: " ").lowercased().contains(q) }
            return item.kindLabel.lowercased().contains(q)
        }
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
        // Do not auto-select first row to avoid random-looking blue highlight.
        // Selection appears only after keyboard navigation.
    }

    func clear() {
        store.clear()
        refresh()
    }

    func copyBack(_ item: ClipItem) {
        pb.clearContents()
        switch item.kind {
        case .text:
            pb.setString(item.text ?? "", forType: .string)
        case .image:
            if let path = item.imagePath, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                pb.setData(data, forType: .png)
            }
        case .files:
            let urls = (item.filePaths ?? []).map { URL(fileURLWithPath: $0) } as [NSURL]
            pb.writeObjects(urls)
        }
        suppressNextOwnedFingerprint = store.fingerprint(of: item)
        showToast("已复制到剪贴板")
    }

    func togglePin(_ item: ClipItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].pinned.toggle()
        store.overwrite(items)
        refresh()
    }

    func selectNext() {
        let list = filteredItems
        guard !list.isEmpty else { return }
        guard let current = selectedId, let idx = list.firstIndex(where: { $0.id == current }) else {
            selectedId = list.first?.id; return
        }
        selectedId = list[min(idx + 1, list.count - 1)].id
    }

    func selectPrev() {
        let list = filteredItems
        guard !list.isEmpty else { return }
        guard let current = selectedId, let idx = list.firstIndex(where: { $0.id == current }) else {
            selectedId = list.first?.id; return
        }
        selectedId = list[max(idx - 1, 0)].id
    }

    func copySelected() {
        guard let id = selectedId, let item = filteredItems.first(where: { $0.id == id }) else { return }
        copyBack(item)
    }

    func exportJSON() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "cliptrail-history.json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            let data = try? JSONEncoder().encode(items)
            if let d = data, (try? d.write(to: url)) != nil {
                showToast("导出成功")
            } else {
                showToast("导出失败")
            }
        }
    }

    func importJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url,
           let data = try? Data(contentsOf: url),
           let incoming = try? JSONDecoder().decode([ClipItem].self, from: data) {
            var merged = incoming + items
            // dedupe by fingerprint
            var seen = Set<String>()
            merged = merged.filter {
                let fp = store.fingerprint(of: $0)
                if seen.contains(fp) { return false }
                seen.insert(fp)
                return true
            }
            store.overwrite(merged)
            refresh()
            showToast("导入成功")
        } else {
            showToast("导入取消/失败")
        }
    }

    func toggleLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try addLoginItem()
                launchAtLogin = true
                showToast("已开启开机自启")
            } else {
                try removeLoginItem()
                launchAtLogin = false
                showToast("已关闭开机自启")
            }
        } catch {
            launchAtLogin = false
            NSLog("LaunchAtLogin update failed: \(error)")
            showToast("开机自启设置失败")
        }
    }

    private func addLoginItem() throws {
        let appPath = Bundle.main.bundleURL.path
        // remove stale item first (idempotent)
        _ = runAppleScript("tell application \"System Events\" to delete login item \"ClipTrail\"")
        let script = "tell application \"System Events\" to make login item at end with properties {name:\"ClipTrail\", path:\"\(appPath)\", hidden:false}"
        let status = runAppleScript(script)
        if status != 0 { throw NSError(domain: "cliptrail.loginitem", code: Int(status)) }
    }

    private func removeLoginItem() throws {
        let status = runAppleScript("tell application \"System Events\" to delete login item \"ClipTrail\"")
        // deleting non-existent item may fail; tolerate common not-found cases
        if status != 0 {
            NSLog("remove login item returned: \(status)")
        }
    }

    private func detectLoginItemEnabled() -> Bool {
        // returns true/false via osascript output
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = [
            "-e",
            "tell application \"System Events\" to (name of login items) contains \"ClipTrail\""
        ]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return false }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            return text == "true"
        } catch {
            return false
        }
    }

    @discardableResult
    private func runAppleScript(_ script: String) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            return -1
        }
    }

    func checkForUpdates() {
        checkingUpdate = true
        guard let url = URL(string: "https://api.github.com/repos/stanley2312831/cliptrail/releases/latest") else {
            checkingUpdate = false; return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self else { return }
            defer { DispatchQueue.main.async { self.checkingUpdate = false } }
            guard let data = data else { return }
            struct Asset: Decodable { let name: String; let browser_download_url: String }
            struct Release: Decodable { let tag_name: String; let body: String?; let html_url: String; let assets: [Asset] }
            guard let release = try? JSONDecoder().decode(Release.self, from: data) else { return }
            let latest = release.tag_name.replacingOccurrences(of: "v", with: "")
            let current = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
            guard self.isVersion(latest, greaterThan: current) else { return }
            guard let dmgAsset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }),
                  let dmgUrl = URL(string: dmgAsset.browser_download_url),
                  let releaseUrl = URL(string: release.html_url) else { return }
            DispatchQueue.main.async {
                self.updateInfo = UpdateInfo(version: latest, notes: release.body ?? "", dmgUrl: dmgUrl, releaseUrl: releaseUrl)
            }
        }.resume()
    }

    func installUpdateInApp() {
        guard let update = updateInfo else { return }
        updatingNow = true
        let tempDMG = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ClipTrail-latest.dmg")
        URLSession.shared.downloadTask(with: update.dmgUrl) { [weak self] localURL, _, _ in
            guard let self = self else { return }
            defer { DispatchQueue.main.async { self.updatingNow = false } }
            guard let localURL = localURL else { return }
            do {
                if FileManager.default.fileExists(atPath: tempDMG.path) { try FileManager.default.removeItem(at: tempDMG) }
                try FileManager.default.copyItem(at: localURL, to: tempDMG)
                DispatchQueue.main.async {
                    NSWorkspace.shared.open(tempDMG)
                    self.showToast("已下载更新，正在打开安装包")
                }
            } catch {
                DispatchQueue.main.async { self.showToast("下载更新失败") }
            }
        }.resume()
    }

    private func isVersion(_ a: String, greaterThan b: String) -> Bool {
        let av = a.split(separator: ".").compactMap { Int($0) }
        let bv = b.split(separator: ".").compactMap { Int($0) }
        let n = max(av.count, bv.count)
        for i in 0..<n {
            let x = i < av.count ? av[i] : 0
            let y = i < bv.count ? bv[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private func showToast(_ text: String) {
        toastMessage = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.toastMessage == text { self?.toastMessage = nil }
        }
    }

    private func pollClipboard() {
        if pb.changeCount != changeCount {
            changeCount = pb.changeCount
            if let item = captureCurrentClipboard() {
                let fp = store.fingerprint(of: item)
                if let owned = suppressNextOwnedFingerprint, owned == fp {
                    suppressNextOwnedFingerprint = nil
                    return
                }
                store.append(item)
                refresh()
            }
        }
    }

    private func captureCurrentClipboard() -> ClipItem? {
        let id = UUID()
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            return ClipItem(id: id, kind: .files, text: nil, imagePath: nil, filePaths: urls.map { $0.path }, timestamp: Date(), pinned: false)
        }
        if let pngData = pb.data(forType: .png), !pngData.isEmpty {
            let out = store.imageFileURL(for: id)
            try? pngData.write(to: out)
            return ClipItem(id: id, kind: .image, text: nil, imagePath: out.path, filePaths: nil, timestamp: Date(), pinned: false)
        }
        if let tiffData = pb.data(forType: .tiff),
           let image = NSImage(data: tiffData),
           let rep = NSBitmapImageRep(data: image.tiffRepresentation ?? Data()),
           let png = rep.representation(using: .png, properties: [:]) {
            let out = store.imageFileURL(for: id)
            try? png.write(to: out)
            return ClipItem(id: id, kind: .image, text: nil, imagePath: out.path, filePaths: nil, timestamp: Date(), pinned: false)
        }
        if let text = pb.string(forType: .string) {
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty { return nil }
            return ClipItem(id: id, kind: .text, text: clean, imagePath: nil, filePaths: nil, timestamp: Date(), pinned: false)
        }
        return nil
    }
}

struct RowView: View {
    let item: ClipItem
    let selected: Bool
    let onCopy: () -> Void
    let onPin: () -> Void

    var body: some View {
        Button(action: onCopy) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(item.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(item.pinned ? "取消置顶" : "置顶") { onPin() }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    Text(item.kindLabel)
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }

                if item.kind == .image, let path = item.imagePath, let nsimg = NSImage(contentsOfFile: path) {
                    Image(nsImage: nsimg)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                if item.kind == .files, let filePaths = item.filePaths {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(filePaths.prefix(3)), id: \.self) { p in
                            Text(URL(fileURLWithPath: p).lastPathComponent)
                                .font(.subheadline)
                                .lineLimit(1)
                        }
                        if filePaths.count > 3 {
                            Text("+\(filePaths.count - 3) more")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(item.preview)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.6), lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
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
                Button(model.checkingUpdate ? "检查中..." : "检查更新") { model.checkForUpdates() }
                    .disabled(model.checkingUpdate || model.updatingNow)
                Button("导出JSON") { model.exportJSON() }
                Button("导入JSON") { model.importJSON() }
                Toggle("开机自启", isOn: Binding(get: { model.launchAtLogin }, set: { model.toggleLaunchAtLogin($0) }))
                    .toggleStyle(.switch)
                    .frame(width: 130)
                Button("清空") { model.clear() }
                Button("刷新") { model.refresh() }
            }

            if let up = model.updateInfo {
                HStack(spacing: 8) {
                    Text("发现新版本 v\(up.version)").font(.subheadline).bold()
                    Spacer()
                    Button(model.updatingNow ? "下载中..." : "软件内更新") { model.installUpdateInApp() }
                        .disabled(model.updatingNow)
                    Button("发布页") { NSWorkspace.shared.open(up.releaseUrl) }
                }
                .padding(8)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            TextField("搜索剪贴板历史...", text: $model.query)
                .textFieldStyle(.roundedBorder)

            if model.filteredItems.isEmpty {
                Spacer()
                Text("暂无记录")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(model.filteredItems) { item in
                                RowView(item: item, selected: item.id == model.selectedId, onCopy: {
                                    model.copyBack(item)
                                }, onPin: {
                                    model.togglePin(item)
                                })
                                .id(item.id)
                                .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                    }
                    .onChange(of: model.filteredItems.first?.id) { _ in
                        if let first = model.filteredItems.first?.id {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                proxy.scrollTo(first, anchor: .top)
                            }
                        }
                    }
                    .onChange(of: model.selectedId) { id in
                        if let id {
                            withAnimation(.easeInOut(duration: 0.1)) {
                                proxy.scrollTo(id, anchor: .center)
                            }
                        }
                    }
                }
            }

            HStack {
                Text("快捷键：Option + V 呼出/隐藏")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("键盘：↑/↓ 选择，Enter 复制，Esc 关闭")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("退出软件") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
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
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var localMonitor: Any?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let root = ContentView(model: model)
        let hosting = NSHostingController(rootView: root)

        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 640, height: 460)

        model.startWatching()
        setupStatusBar()
        setupHotkeyMonitor()
        setupKeyboardMonitor()
        showPopover()
        model.checkForUpdates()
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "📋"
        statusItem?.button?.action = #selector(togglePopoverFromStatusItem)
        statusItem?.button?.target = self
    }

    private func setupKeyboardMonitor() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            switch event.keyCode {
            case UInt16(kVK_DownArrow):
                self.model.selectNext(); return nil
            case UInt16(kVK_UpArrow):
                self.model.selectPrev(); return nil
            case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
                self.model.copySelected(); return nil
            case UInt16(kVK_Escape):
                self.popover.performClose(nil); return nil
            default:
                let isOptionV = event.modifierFlags.contains(.option) && event.keyCode == UInt16(kVK_ANSI_V)
                if isOptionV {
                    self.togglePopover(); return nil
                }
                return event
            }
        }
    }

    private func setupHotkeyMonitor() {
        let hotKeyID = EventHotKeyID(signature: OSType(0x4354524C), id: 1)
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let callback: EventHandlerUPP = { _, event, userData in
            guard let event = event, let userData = userData else { return noErr }
            var hkID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            if status == noErr, hkID.id == 1 {
                let app = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { app.togglePopover() }
            }
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, selfPtr, &eventHandlerRef)
        RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(optionKey), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    @objc private func togglePopoverFromStatusItem() { togglePopover() }

    private func togglePopover() {
        if popover.isShown { popover.performClose(nil) }
        else { showPopover() }
    }

    @objc private func showPopover() {
        guard let button = statusItem?.button else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        model.refresh()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopWatching()
        if let l = localMonitor { NSEvent.removeMonitor(l) }
        if let hk = hotKeyRef { UnregisterEventHotKey(hk) }
        if let eh = eventHandlerRef { RemoveEventHandler(eh) }
    }
}

func runGUI() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.setActivationPolicy(.accessory)
    app.delegate = delegate
    app.run()
}

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--help" {
    print("ClipTrail GUI app. Launch directly from Applications.")
} else {
    runGUI()
}
