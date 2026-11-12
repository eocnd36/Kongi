import AppKit
import ClaudeUsageCore
import SwiftUI

/// 확장 (마켓플레이스): 다른 사람이 GitHub에 올린 작은 프로그램을 받아 Kongi가 실행해 줍니다.
/// 확장은 `$KONGI notify …`·`$KONGI run …`으로 아일랜드에 말을 겁니다 (개발자는 확장 없이 같은 명령을 바로 써도 됨).
///
/// 확장 = GitHub 저장소(또는 그 안의 폴더) + `kongi-extension.json` { "name", "description", "run": "main.sh" }.
@MainActor
final class ExtensionStore: ObservableObject {
    struct Installed: Identifiable, Equatable {
        var id: String { folder.lastPathComponent }
        let folder: URL
        let manifest: ExtensionManifest
        let source: String
    }

    struct CatalogEntry: Codable, Identifiable, Equatable {
        var id: String { source }
        let name: String
        let description: String
        let source: String
        var author: String?
    }

    @Published private(set) var installed: [Installed] = []
    @Published private(set) var catalog: [CatalogEntry] = []
    @Published private(set) var status: [String: String] = [:]
    @Published private(set) var busy = false
    @Published var message: String?

    private var running: [String: Process] = [:]
    private static let disabledKey = "disabledExtensions"
    private static let maxDownload = 20_000_000

    static var directory: URL { HookPaths.supportDirectory.appendingPathComponent("extensions", isDirectory: true) }

    /// 확장이 쓰는 `kongi` 명령 (앱 안의 도우미)
    static var commandPath: String? { Bundle.main.url(forAuxiliaryExecutable: HookPaths.helperName)?.path }

    private var disabled: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.disabledKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.disabledKey) }
    }

    func isEnabled(_ item: Installed) -> Bool { !disabled.contains(item.id) }
    func isRunning(_ item: Installed) -> Bool { running[item.id] != nil }

    func start() {
        catalog = Self.bundledCatalog
        refreshBundled()
        reload()
        for item in installed where isEnabled(item) { launch(item) }
    }

    // MARK: Kongi가 만든 확장 (앱 안에 들어 있음)

    /// 앱 안의 extensions/ — 목록에 늘 보이고, 내려받지 않고 바로 설치합니다.
    private static var bundledDirectory: URL? { Bundle.main.url(forResource: "extensions", withExtension: nil) }

    private static var bundledCatalog: [CatalogEntry] {
        guard let url = bundledDirectory?.appendingPathComponent("catalog.json"), let data = try? Data(contentsOf: url) else { return [] }
        return ((try? JSONDecoder().decode([CatalogEntry].self, from: data)) ?? []).filter { bundledFolder(for: $0.source) != nil }
    }

    /// "eocnd36/Kongi/extensions/<이름>"이 앱 안에 있으면 그 폴더
    private static func bundledFolder(for text: String) -> URL? {
        guard let source = ExtensionSource(text), source.owner == "eocnd36", source.repo == "Kongi",
              source.path.hasPrefix("extensions/"), let directory = bundledDirectory else { return nil }
        let folder = directory.appendingPathComponent(String(source.path.dropFirst("extensions/".count)), isDirectory: true)
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent(ExtensionManifest.fileName).path) ? folder : nil
    }

    /// 앱이 업데이트되어 설치해 둔 Kongi 확장보다 새 버전이 들어 있으면 바꿔 둡니다.
    private func refreshBundled() {
        for entry in Self.bundledCatalog {
            guard let source = ExtensionSource(entry.source), let bundled = Self.bundledFolder(for: entry.source) else { continue }
            let destination = Self.directory.appendingPathComponent(source.folderName, isDirectory: true)
            func version(_ folder: URL) -> String? {
                (try? Data(contentsOf: folder.appendingPathComponent(ExtensionManifest.fileName)))
                    .flatMap { try? JSONDecoder().decode(ExtensionManifest.self, from: $0) }?.version
            }
            guard FileManager.default.fileExists(atPath: destination.path), version(destination) != version(bundled) else { continue }
            _ = try? place(copyOf: bundled, as: source)
        }
    }

    func reload() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        installed = folders.filter { !$0.lastPathComponent.hasPrefix(".") }.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(ExtensionManifest.fileName)),
                  let manifest = try? JSONDecoder().decode(ExtensionManifest.self, from: data) else { return nil }
            let source = (try? String(contentsOf: folder.appendingPathComponent(".kongi-source"), encoding: .utf8)) ?? folder.lastPathComponent
            return Installed(folder: folder, manifest: manifest, source: source)
        }.sorted { $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedAscending }
    }

    // MARK: Running

    private func launch(_ item: Installed) {
        guard running[item.id] == nil, let executable = item.manifest.executable(in: item.folder) else {
            if item.manifest.executable(in: item.folder) == nil { status[item.id] = String(localized: "Can't find the file to run") }
            return
        }
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = item.folder
        process.environment = Self.environment(for: item)
        // 출력은 확장 폴더의 기록 파일로 (설정에서 열어 볼 수 있음)
        let log = item.folder.appendingPathComponent("extension.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: log) {
            process.standardOutput = handle
            process.standardError = handle
        }
        let id = item.id
        process.terminationHandler = { finished in
            let code = finished.terminationStatus
            Task { @MainActor [weak self] in
                guard let self, self.running[id] === finished else { return }
                self.running[id] = nil
                self.status[id] = code == 0 ? String(localized: "Finished") : String(localized: "Stopped (code \(code))")
            }
        }
        do {
            try process.run()
            running[id] = process
            status[id] = String(localized: "Running")
        } catch {
            status[id] = String(localized: "Couldn't start")
        }
    }

    private static func environment(for item: Installed) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["KONGI"] = commandPath
        environment["KONGI_EXTENSION"] = item.id
        environment["KONGI_EXTENSION_NAME"] = item.manifest.name
        return environment
    }

    private func stop(_ id: String) {
        AppServices.shared.tasks.removeWidgets(owner: id)
        guard let process = running.removeValue(forKey: id) else { return }
        process.terminate()
        status[id] = String(localized: "Off")
    }

    /// 확장의 `events` 파일에 이벤트를 알립니다: 이벤트 이름은 첫 인자와 KONGI_EVENT, 내용은 stdin JSON.
    func emit(_ name: String, _ payload: [String: JSONValue]) {
        var payload = payload
        payload["event"] = .string(name)
        guard let data = try? JSONEncoder().encode(JSONValue.object(payload)) else { return }
        for item in installed where isEnabled(item) {
            guard let handler = item.manifest.file(item.manifest.events, in: item.folder) else { continue }
            let process = Process()
            process.executableURL = handler
            process.arguments = [name]
            process.currentDirectoryURL = item.folder
            var environment = Self.environment(for: item)
            environment["KONGI_EVENT"] = name
            process.environment = environment
            let input = Pipe()
            process.standardInput = input
            if let log = try? FileHandle(forWritingTo: item.folder.appendingPathComponent("extension.log")) {
                log.seekToEndOfFile()
                process.standardOutput = log
                process.standardError = log
            }
            guard (try? process.run()) != nil else { continue }
            input.fileHandleForWriting.write(data)
            try? input.fileHandleForWriting.close()
        }
    }

    func stopAll() { running.keys.forEach(stop) }

    func setEnabled(_ item: Installed, _ on: Bool) {
        if on {
            disabled.remove(item.id)
            launch(item)
        } else {
            disabled.insert(item.id)
            stop(item.id)
        }
        objectWillChange.send()
    }

    func restart(_ item: Installed) {
        stop(item.id)
        launch(item)
    }

    func remove(_ item: Installed) {
        stop(item.id)
        // 확장이 바꿔 둔 설정을 되돌릴 기회 (최대 10초)
        if let uninstall = item.manifest.file(item.manifest.uninstall, in: item.folder) {
            let process = Process()
            process.executableURL = uninstall
            process.currentDirectoryURL = item.folder
            process.environment = Self.environment(for: item)
            if (try? process.run()) != nil {
                let deadline = Date().addingTimeInterval(10)
                while process.isRunning, Date() < deadline { usleep(50_000) }
                if process.isRunning { process.terminate() }
            }
        }
        try? FileManager.default.removeItem(at: item.folder)
        status[item.id] = nil
        reload()
    }

    // MARK: Installing

    /// Kongi 저장소의 marketplace/catalog.json (누구나 PR로 올릴 수 있는 목록)
    func loadCatalog() async {
        let repository = AppInfo.repositoryURL ?? URL(string: "https://github.com/eocnd36/Kongi")!
        let parts = repository.path.split(separator: "/")
        guard parts.count >= 2,
              let url = URL(string: "https://raw.githubusercontent.com/\(parts[0])/\(parts[1])/HEAD/marketplace/catalog.json"),
              let result = try? await URLSession.shared.data(from: url),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let entries = try? JSONDecoder().decode([CatalogEntry].self, from: result.0) else { return }
        // 앱 안의 목록 + 온라인 목록 (같은 것은 한 번만)
        let bundled = Self.bundledCatalog
        catalog = bundled + entries.filter { entry in ExtensionSource(entry.source) != nil && !bundled.contains { $0.source == entry.source } }
    }

    func install(_ text: String) async {
        guard let source = ExtensionSource(text) else {
            message = String(localized: "Enter a GitHub repository, like owner/repo or owner/repo/folder.")
            return
        }
        let bundled = Self.bundledFolder(for: text)
        // Kongi가 만든 확장은 앱과 함께 온 것이라 묻지 않습니다.
        guard bundled != nil || confirm(source) else { return }
        busy = true
        defer { busy = false }
        do {
            let item: String
            if let bundled { item = try place(copyOf: bundled, as: source) } else { item = try await download(source) }
            reload()
            if let fresh = installed.first(where: { $0.id == item }) {
                disabled.remove(item)
                restart(fresh)
            }
            message = String(localized: "Installed.")
        } catch let error as InstallError {
            message = error.text
        } catch {
            message = String(localized: "Couldn't download it. Check the address and your connection.")
        }
    }

    private struct InstallError: Error { let text: String }

    /// 확장은 내 권한으로 실행되므로, 설치 전에 꼭 묻습니다.
    private func confirm(_ source: ExtensionSource) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Install “\(source.owner)/\(source.repo)”?")
        alert.informativeText = String(localized: "Extensions run on your Mac with your permissions, like any app you install. Only install extensions from people you trust.")
        alert.addButton(withTitle: String(localized: "Install"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "View on GitHub"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return true
        case .alertThirdButtonReturn: NSWorkspace.shared.open(source.pageURL); return false
        default: return false
        }
    }

    /// 저장소 zip을 받아 풀고, 확인을 거친 확장 폴더만 설치 폴더로 옮깁니다. 돌려주는 값은 설치 폴더 이름.
    private func download(_ source: ExtensionSource) async throws -> String {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let (data, response) = try await URLSession.shared.data(from: source.archiveURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw InstallError(text: String(localized: "That repository wasn't found, or it's private."))
        }
        guard data.count < Self.maxDownload else { throw InstallError(text: String(localized: "That repository is too large to install.")) }

        let work = Self.directory.appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }
        let zip = work.appendingPathComponent("source.zip")
        try data.write(to: zip)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, work.appendingPathComponent("x").path]
        try unzip.run()
        unzip.waitUntilExit()

        // GitHub zip은 맨 위에 "<repo>-<커밋>" 폴더 하나가 있습니다.
        let top = try fileManager.contentsOfDirectory(at: work.appendingPathComponent("x"), includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
        guard unzip.terminationStatus == 0, top.count == 1 else { throw InstallError(text: String(localized: "That download isn't a valid extension.")) }
        let folder = source.path.isEmpty ? top[0] : top[0].appendingPathComponent(source.path)
        return try place(folder, as: source)
    }

    /// 앱 안의 확장을 복사해 설치합니다 (확인 과정은 내려받은 것과 같음).
    @discardableResult
    private func place(copyOf bundled: URL, as source: ExtensionSource) throws -> String {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let work = Self.directory.appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: work) }
        try fileManager.copyItem(at: bundled, to: work)
        return try place(work, as: source)
    }

    /// 확인을 거친 확장 폴더만 설치 폴더로 옮깁니다. 돌려주는 값은 설치 폴더 이름.
    private func place(_ folder: URL, as source: ExtensionSource) throws -> String {
        let fileManager = FileManager.default
        guard let manifestData = try? Data(contentsOf: folder.appendingPathComponent(ExtensionManifest.fileName)),
              let manifest = try? JSONDecoder().decode(ExtensionManifest.self, from: manifestData) else {
            throw InstallError(text: String(localized: "There's no kongi-extension.json there."))
        }
        guard ExtensionManifest.isSafeTree(folder), manifest.executable(in: folder) != nil else {
            throw InstallError(text: String(localized: "That extension points outside its own folder, so it wasn't installed."))
        }

        let destination = Self.directory.appendingPathComponent(source.folderName, isDirectory: true)
        stop(source.folderName)
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: folder, to: destination)
        try? "\(source.owner)/\(source.repo)\(source.path.isEmpty ? "" : "/" + source.path)"
            .write(to: destination.appendingPathComponent(".kongi-source"), atomically: true, encoding: .utf8)
        for file in [manifest.executable(in: destination), manifest.file(manifest.events, in: destination), manifest.file(manifest.uninstall, in: destination)] {
            if let file { try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
        }
        return source.folderName
    }
}

// MARK: - 설정 화면

struct ExtensionsPane: View {
    @ObservedObject var store: ExtensionStore
    @AppStorage(AppSettings.appNotices) private var appNotices = true
    @State private var address = ""

    var body: some View {
        KPage(title: String(localized: "Extensions"),
              subtitle: String(localized: "Add features made by others, or send to the island from your own apps.")) {
            KLabel(String(localized: "Marketplace"))
            KCard {
                if store.catalog.isEmpty {
                    Text("No extensions listed yet. You can still install one from GitHub below.")
                        .font(.system(size: 12)).foregroundStyle(KongiTheme.secondary)
                }
                ForEach(store.catalog) { entry in
                    KRow(title: entry.name, detail: entry.description + (entry.author.map { " · \($0)" } ?? "")) {
                        if store.installed.contains(where: { $0.source == entry.source }) {
                            Label("Installed", systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(KongiTheme.green)
                        } else {
                            KButton(title: String(localized: "Install"), symbol: "arrow.down.circle") {
                                Task { await store.install(entry.source) }
                            }
                        }
                    }
                    if entry != store.catalog.last { KDivider() }
                }
                KDivider()
                HStack(spacing: 8) {
                    TextField("owner/repo", text: $address)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await store.install(address) } }
                    KButton(title: String(localized: "Install from GitHub"), symbol: "arrow.down.circle", style: .primary) {
                        Task { await store.install(address) }
                    }
                    .disabled(store.busy || address.isEmpty)
                }
                if store.busy { ProgressView().controlSize(.small) }
                if let message = store.message {
                    Text(verbatim: message).font(.system(size: 12)).foregroundStyle(KongiTheme.secondary)
                }
            }

            if !store.installed.isEmpty {
                KLabel(String(localized: "Installed"))
                KCard {
                    ForEach(store.installed) { item in
                        InstalledRow(store: store, item: item)
                        if item != store.installed.last { KDivider() }
                    }
                }
            }

            KLabel(String(localized: "For developers"))
            KCard {
                KToggleRow(title: String(localized: "Let apps on this Mac post to the island"),
                           detail: String(localized: "Use the kongi command from your own apps, scripts and build tools. Nothing to install."),
                           isOn: $appNotices)
                if let path = ExtensionStore.commandPath {
                    CommandSnippet(lines: [
                        "alias kongi=\"\(path)\"",
                        "kongi notify \"Deploy finished\" \"api · 42s\" --symbol paperplane.fill",
                        "kongi run -- npm run build",
                        "kongi task backup --progress 40%",
                        "kongi widget weather --title Seoul --value 7°",
                        "kongi status",
                    ])
                    Text("kongi run shows progress and a pass/fail ring in the menu bar window, and tells you in the island when it ends.")
                        .font(.system(size: 12)).foregroundStyle(KongiTheme.secondary)
                    KDivider()
                    Text("Codex: add this line to ~/.codex/config.toml to hear when Codex finishes.")
                        .font(.system(size: 12, weight: .medium))
                    CommandSnippet(lines: ["notify = [\"\(path)\", \"codex\"]"])
                }
            }
        }
        .task { await store.loadCatalog() }
    }
}

private struct InstalledRow: View {
    @ObservedObject var store: ExtensionStore
    let item: ExtensionStore.Installed

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: item.manifest.name).font(.system(size: 13.5, weight: .medium))
                Text(verbatim: [item.source, store.status[item.id]].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11.5)).foregroundStyle(KongiTheme.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { NSWorkspace.shared.open(item.folder.appendingPathComponent("extension.log")) } label: { Image(systemName: "doc.text") }
                .buttonStyle(.borderless).help(Text("Open the log"))
            Button { store.restart(item) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help(Text("Restart"))
            Button { store.remove(item) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help(Text("Remove"))
            Toggle("", isOn: Binding(get: { store.isEnabled(item) }, set: { store.setEnabled(item, $0) }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small).tint(KongiTheme.accent)
        }
    }
}

/// 복사 버튼이 있는 명령 줄
private struct CommandSnippet: View {
    let lines: [String]
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top) {
            Text(verbatim: lines.joined(separator: "\n"))
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                copied = true
            } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                .buttonStyle(.borderless).help(Text("Copy"))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(KongiTheme.code))
    }
}
