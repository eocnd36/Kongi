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

    /// marketplace/catalog-v2.json 한 항목. (예전 앱은 catalog.json만 읽으므로, 새 형식은 이 파일에만 둡니다.)
    struct CatalogEntry: Codable, Identifiable, Equatable {
        struct Localized: Codable, Equatable { var name: String?; var description: String? }

        var id: String { source }
        let name: String
        let description: String
        let source: String
        var author: String?
        /// 최신 버전 (kongi-extension.json의 version). 설치한 것보다 높으면 확장 탭에 "업데이트"가 뜹니다.
        var version: String?
        /// 언어별 이름·설명 (없으면 영어)
        var localized: [String: Localized]?
        /// 버전마다 필요한 Kongi와 받을 커밋. 없으면 version 하나 (최신, 모든 Kongi)
        var versions: [CatalogVersion]?
        /// 이 확장이 하는 일 (kongi-extension.json의 permissions와 같은 값)
        var permissions: [String]?

        /// Kongi 저장소의 확장만 공식 (목록 파일의 표시가 아니라 출처로 판단)
        var isOfficial: Bool { source.hasPrefix("eocnd36/Kongi/extensions/") }

        func title(_ language: String) -> String {
            (localized?[language] ?? localized?[String(language.prefix(2))])?.name ?? name
        }

        func detail(_ language: String) -> String {
            (localized?[language] ?? localized?[String(language.prefix(2))])?.description ?? description
        }

        var allVersions: [CatalogVersion] { versions ?? [CatalogVersion(version: version ?? "0")] }

        /// 이 Kongi에서 돌아가는 가장 새 버전 (없으면 nil: 더 새 Kongi가 필요)
        var compatible: CatalogVersion? { ExtensionCompatibility.best(allVersions, on: AppInfo.version) }

        /// 가장 낮은 요구 버전 ("Kongi 2.3 필요" 안내용)
        var neededKongi: String? {
            allVersions.compactMap(\.minKongi).min { AppUpdate.isNewer($1, than: $0) }
        }
    }

    /// 설치한 확장에 권할 버전: 새 버전, 또는 지금 Kongi에서 안 돌아가면 돌아가는 예전 버전
    struct Recommendation: Equatable {
        let entry: CatalogEntry
        let version: CatalogVersion
        /// 지금 것이 이 Kongi에서 안 돌아가 예전 버전으로 바꾸는 것
        let downgrade: Bool
    }

    @Published private(set) var installed: [Installed] = []
    @Published private(set) var catalog: [CatalogEntry] = []
    @Published private(set) var status: [String: String] = [:]
    @Published private(set) var busy = false
    @Published var message: String?

    private var running: [String: Process] = [:]
    private static let disabledKey = "disabledExtensions"
    /// 사용자가 버전 기록에서 직접 고른 예전 버전 (확장 id → 버전): 앱이 덮어쓰지 않고, 업데이트 알림도 하지 않음
    private static let pinnedKey = "pinnedExtensionVersions"
    /// 이미 알린 확장 업데이트 ("id@버전")
    private static let announcedKey = "announcedExtensionUpdates"
    private var checkTask: Task<Void, Never>?

    var pinned: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Self.pinnedKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.pinnedKey); objectWillChange.send() }
    }
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
        // 앱이 강제로 끝나면(업데이트 설치, killall 등) 확장은 고아로 남아 계속 돕니다. 새로 띄우기 전에 정리합니다.
        let cleanup = Process()
        cleanup.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        cleanup.arguments = ["-P", "1", "-f", NSRegularExpression.escapedPattern(for: Self.directory.path + "/")]
        if (try? cleanup.run()) != nil { cleanup.waitUntilExit() }
        for item in installed where isEnabled(item) { launch(item) }
        // 켤 때와 12시간마다 마켓플레이스를 확인해 확장 업데이트를 알립니다 (앱 업데이트와 같은 주기).
        checkTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.loadCatalog()
                self?.announceUpdates()
                try? await Task.sleep(nanoseconds: 12 * 3600 * NSEC_PER_SEC)
            }
        }
    }

    /// 새 버전이 나온 확장을 버전마다 한 번 알립니다 (고정해 둔 것과, 예전 버전으로 바꾸라는 권유는 알리지 않음).
    private func announceUpdates() {
        guard UserDefaults.standard.bool(forKey: AppSettings.checkForUpdates) else { return }
        var announced = Set(UserDefaults.standard.stringArray(forKey: Self.announcedKey) ?? [])
        let language = Self.language
        for item in installed where pinned[item.id] == nil {
            guard let update = availableUpdate(for: item), !update.downgrade else { continue }
            let key = "\(item.id)@\(update.version.version)"
            guard announced.insert(key).inserted else { continue }
            let name = update.entry.title(language)
            let version = update.version.version
            let title = String(localized: "\(name) \(version) is available")
            let detail = update.version.notes?.text(language) ?? String(localized: "Update it in Settings → Extensions.")
            AppServices.shared.devices.post(.init(
                key: "extension-update-\(key)", symbol: "puzzlepiece.extension.fill", tint: KongiTheme.green,
                title: title, detail: detail, action: .openExtensions
            ), for: 8)
            Notifier.post(title: title, body: detail, phone: false)
        }
        UserDefaults.standard.set(Array(announced.suffix(200)), forKey: Self.announcedKey)
    }

    // MARK: Kongi가 만든 확장 (앱 안에 들어 있음)

    /// 앱 안의 extensions/ — 목록에 늘 보이고, 내려받지 않고 바로 설치합니다.
    private static var bundledDirectory: URL? { Bundle.main.url(forResource: "extensions", withExtension: nil) }

    private static var bundledCatalog: [CatalogEntry] {
        guard let directory = bundledDirectory,
              let data = (try? Data(contentsOf: directory.appendingPathComponent("catalog-v2.json")))
                ?? (try? Data(contentsOf: directory.appendingPathComponent("catalog.json"))) else { return [] }
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
            // 앱에 든 것이 더 새것일 때만 (GitHub에서 받은 더 새 버전을 앱의 옛 버전으로 되돌리지 않게).
            // 사용자가 버전 기록에서 고른 예전 버전도 그대로 둡니다.
            let pinned = UserDefaults.standard.dictionary(forKey: Self.pinnedKey) as? [String: String] ?? [:]
            guard pinned[source.folderName] == nil, FileManager.default.fileExists(atPath: destination.path), let new = version(bundled),
                  AppUpdate.isNewer(new, than: version(destination) ?? "0") else { continue }
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
        // 이 Kongi보다 새 Kongi가 필요한 확장은 실행하지 않습니다 (확장 탭에서 맞는 버전으로 바꿀 수 있음).
        if !runsHere(item) {
            let needed = item.manifest.minKongi ?? ""
            status[item.id] = String(localized: "Needs Kongi \(needed)")
            return
        }
        // 누를 때만 도는 일(actions)만 있는 확장은 띄울 것이 없습니다.
        if item.manifest.run == nil, !(item.manifest.actions ?? []).isEmpty {
            status[item.id] = String(localized: "Ready")
            return
        }
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
        // 확장이 사용자 언어로 글을 쓸 수 있게 (en, ko, ja, zh-Hans, zh-Hant, es, fr, de, it, pt-BR, ru)
        environment["KONGI_LANGUAGE"] = AppLanguage.override ?? Bundle.main.preferredLocalizations.first ?? "en"
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

    // MARK: Actions (아일랜드에서 입력받아 실행)

    struct ActionRef: Identifiable, Equatable {
        let item: Installed
        let action: ExtensionManifest.Action
        var id: String { item.id + "/" + action.id }
    }

    /// 켜 둔 확장들의 일
    var actions: [ActionRef] {
        installed.filter { isEnabled($0) && runsHere($0) }.flatMap { item in (item.manifest.actions ?? []).map { ActionRef(item: item, action: $0) } }
    }

    static var language: String { AppLanguage.override ?? Bundle.main.preferredLocalizations.first ?? "en" }

    /// 확장의 일에 넘길 맥락: 고른 대화(프로젝트 폴더·최근 말·바꾼 파일), 첨부, 답 (아일랜드·휴대폰이 함께 씀)
    static func context(session: AgentSession?, files: [String] = [], answers: [ActionContext.Answer] = [], skip: Bool = false) -> ActionContext {
        ActionContext(
            language: language,
            project: session?.cwd,
            conversation: session?.title,
            messages: (session?.messages.filter { $0.queued != true }.suffix(12) ?? []).map {
                .init(role: $0.role.rawValue, text: String($0.text.prefix(2000)))
            },
            changedFiles: (session?.changes.prefix(30) ?? []).map { Formatters.relativePath($0.path, in: session?.cwd ?? "") },
            files: files,
            answers: answers,
            skipQuestions: skip
        )
    }

    /// "사용하는 것: Claude Code · 파일 읽기" (없으면 빈칸)
    static func permissionText(_ list: [String]?) -> String {
        let names = ExtensionManifest.knownPermissions(list).map { permission -> String in
            switch permission {
            case "claude": return String(localized: "Claude Code (uses your usage)")
            case "files-read": return String(localized: "Reads files")
            case "files-write": return String(localized: "Changes files")
            case "network": return String(localized: "Internet")
            case "processes": return String(localized: "Other apps' info")
            case "notifications": return String(localized: "Notifications")
            default: return String(localized: "Other")
            }
        }
        guard !names.isEmpty else { return "" }
        let joined = names.joined(separator: " · ")
        return String(localized: "Uses: \(joined)")
    }

    /// 입력을 stdin으로 주고 stdout을 결과로 받습니다. 실패하면 stderr 끝부분을 돌려줍니다 (확장 기록에도 남음).
    func perform(_ ref: ActionRef, input: String, choice: String?, context: ActionContext) async -> (text: String, failed: Bool) {
        guard let file = ref.item.manifest.file(ref.action.run, in: ref.item.folder) else {
            return (String(localized: "Can't find the file to run"), true)
        }
        var environment = Self.environment(for: ref.item)
        environment["KONGI_ACTION"] = ref.action.id
        environment["KONGI_CHOICE"] = choice ?? ""
        // 프로젝트·대화·첨부·답은 JSON 파일로 (나만 읽을 수 있게, 끝나면 지움)
        let contextFile = FileManager.default.temporaryDirectory.appendingPathComponent("kongi-action-\(UUID().uuidString).json")
        if let data = try? JSONEncoder().encode(context) {
            FileManager.default.createFile(atPath: contextFile.path, contents: data, attributes: [.posixPermissions: 0o600])
            environment["KONGI_CONTEXT"] = contextFile.path
        }
        defer { try? FileManager.default.removeItem(at: contextFile) }
        let folder = ref.item.folder
        let timeout = min(max(ref.action.timeout ?? 120, 5), 600)
        return await Task.detached(priority: .userInitiated) {
            // Claude Code를 쓰는 확장을 위해 claude 위치도 알려 줍니다 (앱은 셸 PATH를 모름).
            if let claude = ClaudeRunner.executable()?.path { environment["KONGI_CLAUDE"] = claude }
            let process = Process()
            process.executableURL = file
            process.currentDirectoryURL = folder
            process.environment = environment
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr
            guard (try? process.run()) != nil else { return (String(localized: "Couldn't start"), true) }
            let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
            // 결과와 오류를 함께 읽어야 한쪽이 가득 차 멈추지 않습니다.
            var errorData = Data()
            let errorReader = DispatchQueue(label: "extension.action.stderr")
            errorReader.async { errorData = stderr.fileHandleForReading.readDataToEndOfFile() }
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timer.cancel()
            errorReader.sync {}
            let log = folder.appendingPathComponent("extension.log")
            if !errorData.isEmpty, let handle = try? FileHandle(forWritingTo: log) {
                handle.seekToEndOfFile()
                handle.write(errorData)
                try? handle.close()
            }
            let text = String(decoding: output.prefix(200_000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if process.terminationReason == .uncaughtSignal {
                return (String(localized: "It took too long and was stopped."), true)
            }
            guard process.terminationStatus == 0, !text.isEmpty else {
                let message = String(decoding: errorData.suffix(600), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                return (message.isEmpty ? String(localized: "Something went wrong. See the extension's log.") : message, true)
            }
            return (text, false)
        }.value
    }

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
        var pins = pinned
        pins[item.id] = nil
        pinned = pins
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
              let url = URL(string: "https://raw.githubusercontent.com/\(parts[0])/\(parts[1])/HEAD/marketplace/catalog-v2.json"),
              let result = try? await URLSession.shared.data(from: url),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let entries = try? JSONDecoder().decode([CatalogEntry].self, from: result.0) else { return }
        // 앱 안의 목록 + 온라인 목록 (같은 것은 한 번만)
        let bundled = Self.bundledCatalog
        // 온라인 것이 더 새 정보 (버전·번역). 공식 확장이 위로.
        let online = entries.filter { ExtensionSource($0.source) != nil }
        let merged = online + bundled.filter { entry in !online.contains { $0.source == entry.source } }
        catalog = merged.filter(\.isOfficial) + merged.filter { !$0.isOfficial }
    }

    /// 이 Kongi에서 돌아가는지 (설치한 확장의 minKongi)
    func runsHere(_ item: Installed) -> Bool { ExtensionCompatibility.runs(minKongi: item.manifest.minKongi, on: AppInfo.version) }

    /// 버전 기록에서 고른 버전을 설치합니다. 추천(이 Kongi의 최신)이 아니면 고정해 두어 덮어쓰거나 알리지 않습니다.
    func install(version: CatalogVersion, of entry: CatalogEntry) async {
        let item = entry.source
        await install(item, update: true, ref: version.ref)
        guard let installedItem = installed.first(where: { $0.source == item }) else { return }
        var pins = pinned
        pins[installedItem.id] = version == entry.compatible ? nil : version.version
        pinned = pins
    }

    /// 새 버전이 있거나, 지금 것이 이 Kongi에서 안 돌아가 맞는 예전 버전이 있으면 그것
    func availableUpdate(for item: Installed) -> Recommendation? {
        guard let entry = catalog.first(where: { $0.source == item.source }), let best = entry.compatible else { return nil }
        let installed = item.manifest.version ?? "0"
        if !runsHere(item), best.version != installed { return Recommendation(entry: entry, version: best, downgrade: true) }
        return AppUpdate.isNewer(best.version, than: installed) ? Recommendation(entry: entry, version: best, downgrade: false) : nil
    }

    /// 확장만 GitHub에서 새로 받습니다 (앱 업데이트 없이). 이 Kongi에 맞는 버전의 커밋에서 받습니다.
    /// 공식 확장은 다시 묻지 않고, 다른 사람의 확장은 내용이 바뀌었을 수 있으니 다시 묻습니다.
    func update(_ item: Installed) async {
        let recommendation = availableUpdate(for: item)
        await install(item.source, update: true, ref: recommendation?.version.ref)
        // 추천 버전으로 올렸으니 고정을 풉니다.
        var pins = pinned
        pins[item.id] = nil
        pinned = pins
    }

    func install(_ text: String, update: Bool = false, ref: String? = nil) async {
        guard let source = ExtensionSource(text) else {
            message = String(localized: "Enter a GitHub repository, like owner/repo or owner/repo/folder.")
            return
        }
        // 업데이트는 늘 GitHub에서 받습니다 (앱 안의 것은 처음 설치할 때만).
        let bundled = update || ref != nil ? nil : Self.bundledFolder(for: text)
        // Kongi가 만든 확장은 앱과 함께 오거나 Kongi 저장소에서 오므로 묻지 않습니다.
        let official = text.hasPrefix("eocnd36/Kongi/extensions/")
        guard bundled != nil || official || confirm(source) else { return }
        busy = true
        defer { busy = false }
        do {
            let item: String
            if let bundled { item = try place(copyOf: bundled, as: source) } else { item = try await download(source, ref: ref) }
            reload()
            if let fresh = installed.first(where: { $0.id == item }) {
                disabled.remove(item)
                restart(fresh)
            }
            message = update ? String(localized: "Updated.") : String(localized: "Installed.")
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
        var info = String(localized: "Extensions run on your Mac with your permissions, like any app you install. Only install extensions from people you trust.")
        // 마켓플레이스에 적힌 권한이 있으면 함께 보여 줍니다.
        if let entry = catalog.first(where: { ExtensionSource($0.source)?.folderName == source.folderName }) {
            let uses = Self.permissionText(entry.permissions)
            if !uses.isEmpty { info += "\n\n" + uses }
        }
        alert.informativeText = info
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
    private func download(_ source: ExtensionSource, ref: String? = nil) async throws -> String {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let (data, response) = try await URLSession.shared.data(from: source.archiveURL(ref: ref))
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
        guard ExtensionManifest.isSafeTree(folder), manifest.isRunnable(in: folder) else {
            throw InstallError(text: String(localized: "That extension points outside its own folder, so it wasn't installed."))
        }

        let destination = Self.directory.appendingPathComponent(source.folderName, isDirectory: true)
        stop(source.folderName)
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: folder, to: destination)
        try? "\(source.owner)/\(source.repo)\(source.path.isEmpty ? "" : "/" + source.path)"
            .write(to: destination.appendingPathComponent(".kongi-source"), atomically: true, encoding: .utf8)
        let actionFiles = (manifest.actions ?? []).map { manifest.file($0.run, in: destination) }
        for file in [manifest.executable(in: destination), manifest.file(manifest.events, in: destination), manifest.file(manifest.uninstall, in: destination)] + actionFiles {
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
                    let language = ExtensionStore.language
                    let uses = ExtensionStore.permissionText(entry.permissions)
                    KRow(title: entry.title(language), detail: entry.detail(language) + (entry.author.map { " · \($0)" } ?? "") + (uses.isEmpty ? "" : "\n" + uses)) {
                        HStack(spacing: 8) {
                            if entry.isOfficial {
                                Label(String(localized: "Official"), systemImage: "checkmark.seal.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(KongiTheme.accent)
                            }
                            VersionsButton(store: store, entry: entry)
                            if let item = store.installed.first(where: { $0.source == entry.source }), store.availableUpdate(for: item) != nil {
                                KButton(title: String(localized: "Update"), symbol: "arrow.down.circle", style: .primary) {
                                    Task { await store.update(item) }
                                }
                                .disabled(store.busy)
                            } else if store.installed.contains(where: { $0.source == entry.source }) {
                                Label("Installed", systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(KongiTheme.green)
                            } else if let version = entry.compatible {
                                KButton(title: String(localized: "Install"), symbol: "arrow.down.circle") {
                                    Task { await store.install(entry.source, ref: version.ref) }
                                }
                            } else {
                                // 이 Kongi에서 돌아가는 버전이 없음
                                let needed = entry.neededKongi ?? ""
                                Text("Needs Kongi \(needed)").font(.system(size: 12)).foregroundStyle(KongiTheme.secondary)
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
                Text(verbatim: store.catalog.first { $0.source == item.source }?.title(ExtensionStore.language) ?? item.manifest.name)
                    .font(.system(size: 13.5, weight: .medium))
                Text(verbatim: [item.source, store.status[item.id]].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11.5)).foregroundStyle(KongiTheme.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let update = store.availableUpdate(for: item) {
                let version = update.version.version
                // 새 버전, 또는 이 Kongi에서 안 돌아가면 돌아가는 예전 버전으로
                KButton(title: update.downgrade ? String(localized: "Use \(version) for this Kongi") : String(localized: "Update to \(version)"),
                        symbol: update.downgrade ? "arrow.uturn.backward.circle" : "arrow.down.circle", style: .primary) {
                    Task { await store.update(item) }
                }
                .disabled(store.busy)
            }
            Button { NSWorkspace.shared.open(item.folder.appendingPathComponent("extension.log")) } label: { Image(systemName: "doc.text") }
                .buttonStyle(KHoverStyle()).help(Text("Open the log"))
            Button { store.restart(item) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(KHoverStyle()).help(Text("Restart"))
            Button { store.remove(item) } label: { Image(systemName: "trash") }
                .buttonStyle(KHoverStyle()).help(Text("Remove"))
            Toggle("", isOn: Binding(get: { store.isEnabled(item) }, set: { store.setEnabled(item, $0) }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small).tint(KongiTheme.accent)
        }
    }
}

/// 버전 기록: 모든 버전과 바뀐 것, 이 Kongi에 맞는 것은 (추천), 안 맞는 것은 필요한 Kongi 버전
private struct VersionsButton: View {
    @ObservedObject var store: ExtensionStore
    let entry: ExtensionStore.CatalogEntry
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: { Image(systemName: "clock.arrow.circlepath") }
            .buttonStyle(KHoverStyle())
            .help(Text("Versions"))
            .popover(isPresented: $shown, arrowEdge: .bottom) { VersionHistory(store: store, entry: entry) }
    }
}

private struct VersionHistory: View {
    @ObservedObject var store: ExtensionStore
    let entry: ExtensionStore.CatalogEntry

    var body: some View {
        let language = ExtensionStore.language
        let installed = store.installed.first { $0.source == entry.source }
        let recommended = entry.compatible
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: entry.title(language)).font(.system(size: 13, weight: .semibold))
            if let installed, let pinned = store.pinned[installed.id] {
                Text("Kept at \(pinned). Kongi won't replace it or remind you about updates.")
                    .font(.system(size: 11)).foregroundStyle(KongiTheme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(ExtensionCompatibility.newestFirst(entry.allVersions), id: \.version) { version in
                        let runs = ExtensionCompatibility.runs(minKongi: version.minKongi, on: AppInfo.version)
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(verbatim: version.version).font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                                    if version == recommended {
                                        Text("(Recommended)").font(.system(size: 11, weight: .semibold)).foregroundStyle(KongiTheme.accent)
                                    }
                                }
                                if let notes = version.notes?.text(language), !notes.isEmpty {
                                    Text(verbatim: notes).font(.system(size: 11)).foregroundStyle(KongiTheme.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if !runs, let needed = version.minKongi {
                                    Text("Needs Kongi \(needed)").font(.system(size: 11)).foregroundStyle(KongiTheme.orange)
                                }
                            }
                            Spacer(minLength: 8)
                            if installed?.manifest.version == version.version {
                                Label("Installed", systemImage: "checkmark").font(.system(size: 11.5)).foregroundStyle(KongiTheme.green)
                            } else {
                                KButton(title: String(localized: "Install"), style: version == recommended ? .primary : .secondary) {
                                    Task { await store.install(version: version, of: entry) }
                                }
                                .disabled(!runs || store.busy)
                            }
                        }
                        if version != entry.allVersions.min(by: { AppUpdate.isNewer($1.version, than: $0.version) }) { KDivider() }
                    }
                }
            }
            .frame(maxHeight: 320)
            if store.busy { ProgressView().controlSize(.small) }
        }
        .padding(14)
        .frame(width: 340)
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
                .buttonStyle(KHoverStyle()).help(Text("Copy"))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(KongiTheme.code))
    }
}
