import Foundation
import Testing
@testable import ClaudeUsageCore

@Suite struct TaskProgressTests {
    private func feed(_ lines: [String]) -> TaskProgress {
        var progress = TaskProgress()
        lines.forEach { progress.read($0) }
        return progress
    }

    @Test func readsPercentages() {
        let progress = feed(["[webpack] 12% building", "\u{1B}[32m 87.5% \u{1B}[0m emitting", "v1.2.3 shipped"])
        #expect(progress.fraction == 0.875)
        #expect(feed(["used 140% cpu"]).fraction == nil)
    }

    @Test func readsCargoTests() {
        let progress = feed([
            "running 4 tests", "test a ... ok", "test b ... FAILED",
        ])
        #expect(progress.fraction == 0.5)
        #expect(progress.passed == 1 && progress.failed == 1)
        let done = feed([
            "running 2 tests", "test a ... ok", "test b ... ok",
            "test result: ok. 2 passed; 0 failed; 0 ignored",
            "running 1 test", "test c ... FAILED",
            "test result: FAILED. 0 passed; 1 failed; 0 ignored",
        ])
        #expect(done.passed == 2 && done.failed == 1)
        #expect(done.fraction == 1)
    }

    @Test func readsJestAndPytestSummaries() {
        #expect(feed(["Tests:       1 failed, 41 passed, 42 total"]).passed == 41)
        #expect(feed(["Tests:       1 failed, 41 passed, 42 total"]).failed == 1)
        let pytest = feed(["==== 3 failed, 10 passed in 1.20s ===="])
        #expect(pytest.passed == 10 && pytest.failed == 3)
    }

    @Test func parsesExtensionSources() {
        #expect(ExtensionSource("eocnd36/Kongi")?.repo == "Kongi")
        #expect(ExtensionSource("https://github.com/eocnd36/Kongi/tree/main/extensions/hello")?.path == "extensions/hello")
        #expect(ExtensionSource("github.com/a/b.git")?.repo == "b")
        #expect(ExtensionSource("a/b/../../etc") == nil)
        #expect(ExtensionSource("https://evil.example/a/b") == nil)
        #expect(ExtensionSource("a") == nil)
        #expect(ExtensionSource("a/b/c")?.folderName == "a--b--c")
    }

    @Test func keepsExtensionsInsideTheirFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("echo hi".utf8).write(to: root.appendingPathComponent("main.sh"))
        #expect(ExtensionManifest(name: "x", run: "main.sh").executable(in: root) != nil)
        #expect(ExtensionManifest(name: "x", run: "../main.sh").executable(in: root) == nil)
        #expect(ExtensionManifest(name: "x", run: "/bin/sh").executable(in: root) == nil)
        #expect(ExtensionSource("a/b") != nil)
        #expect(ExtensionManifest.isSafeTree(root))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: URL(fileURLWithPath: "/etc"))
        #expect(!ExtensionManifest.isSafeTree(root))
        #expect(ExtensionManifest(name: "x", run: "escape/hosts").executable(in: root) == nil)
        // events·uninstall도 같은 규칙
        let manifest = ExtensionManifest(name: "x", run: "main.sh", events: "main.sh", uninstall: "../x.sh")
        #expect(manifest.file(manifest.events, in: root) != nil)
        #expect(manifest.file(manifest.uninstall, in: root) == nil)
        #expect(manifest.file(nil, in: root) == nil)
    }

    @Test func understandsCodexHooks() throws {
        let decode = { (text: String) in try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
        #expect(HookEvent.looksLikeCodex(try decode(#"{"turn_id":"t1","hook_event_name":"Stop"}"#)))
        #expect(HookEvent.looksLikeCodex(try decode(#"{"transcript_path":"/Users/me/.codex/sessions/r.jsonl"}"#)))
        #expect(!HookEvent.looksLikeCodex(try decode(#"{"transcript_path":"/Users/me/.claude/projects/x.jsonl"}"#)))

        let patch = try decode(#"{"command":"*** Begin Patch\n*** Update File: Sources/App.swift\n@@\n-a\n+b\n*** Add File: README.md\n*** End Patch"}"#)
        let edit = ToolActivity.describe(toolName: "apply_patch", input: patch)
        #expect(edit.kind == .edit && edit.target == "App.swift")
        #expect(ToolActivity.patchedFiles(ToolActivity.commandText(patch)) == ["Sources/App.swift", "README.md"])

        let shell = ToolActivity.describe(toolName: "shell", input: try decode(#"{"command":["bash","-lc","npm test"]}"#))
        #expect(shell.kind == .run && shell.target == "npm test")
        // 셸 스크립트 형태가 아니면 실행될 명령 전체를 보여 줍니다 (마지막 인자만 보이면 승인 화면이 속음).
        #expect(ToolActivity.commandText(try decode(#"{"command":["rm","-rf","/"]}"#)) == "rm -rf /")
        #expect(ToolActivity.commandText(try decode(#"{"command":["bash","-lc","echo hi","extra"]}"#)) == "bash -lc 'echo hi' extra")
        #expect(ToolActivity.commandText(try decode(#"{"command":["sh","-c","it's"]}"#)) == "it's")
        #expect(ToolActivity.commandText(try decode(#"{"command":["/bin/zsh","-lc","ls"]}"#)) == "ls")
        #expect(ToolActivity.commandText(try decode(#"{"command":["/tmp/x/bash","-c","ls"]}"#)) == "/tmp/x/bash -c ls")
        #expect(ToolActivity.shellQuoted("it's") == #"'it'\''s'"#)
    }
}

@Suite struct UpdateNotesTests {
    @Test func picksTheHeadlines() {
        let notes = """
        **Kongi is a Dynamic Island** — intro.

        ### What's new in 2.2

        - **Automatic updates on the Mac** — Settings → General.
        - **The Android app updates itself** — Settings → Updates.
          - nested detail
        - Plain line — with detail

        **Android:** install by hand once.
        """
        #expect(AppUpdate.highlights(notes) == ["Automatic updates on the Mac", "The Android app updates itself", "Plain line"])
        #expect(AppUpdate.highlights("- one\n- two\n- three", limit: 2) == ["one", "two"])
        #expect(AppUpdate.highlights("no list here").isEmpty)
    }
}

@Suite struct TurnEstimateTests {
    @Test func estimatesFromTodosThenHistory() {
        // 5개 중 2개를 3분에 끝냄 → 남은 3개에 4분 30초
        #expect(TurnEstimate.remaining(elapsed: 180, done: 2, total: 5, past: []) == 270)
        // 목록이 없거나 아직 하나도 못 끝냄 → 지난 요청 가운데값(120초) - 지금까지(30초)
        #expect(TurnEstimate.remaining(elapsed: 30, done: 0, total: 5, past: [60, 120, 600]) == 90)
        // 근거 부족 또는 이미 평소보다 오래 걸림 → 어림하지 않음
        #expect(TurnEstimate.remaining(elapsed: 30, done: nil, total: nil, past: [60, 120]) == nil)
        // 이미 대부분보다 오래 걸림 → 그보다 길었던 기록(600초)으로
        #expect(TurnEstimate.remaining(elapsed: 200, done: nil, total: nil, past: [60, 120, 600]) == 400)
        // 지난 어느 기록보다 오래 걸림 → 어림하지 않음
        #expect(TurnEstimate.remaining(elapsed: 700, done: nil, total: nil, past: [60, 120, 600]) == nil)
        #expect(TurnEstimate.remaining(elapsed: 100, done: 5, total: 5, past: []) == nil)
    }
}

@Suite struct ExtensionActionTests {
    @Test func decodesActionsWithLocalizedText() throws {
        let json = #"{"name":"P","actions":[{"id":"a","title":{"en":"Upgrade","ko":"업그레이드","pt-BR":"Melhorar"},"placeholder":"Paste…","run":"a.sh","choices":[{"id":"haiku","title":"Haiku"}]}]}"#
        let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: Data(json.utf8))
        let action = try #require(manifest.actions?.first)
        #expect(manifest.run == nil)
        #expect(action.title.text("ko") == "업그레이드")
        #expect(action.title.text("pt-BR") == "Melhorar")
        #expect(action.title.text("pt") == "Melhorar" || action.title.text("pt") == "Upgrade")
        #expect(action.title.text("ja") == "Upgrade")
        #expect(action.placeholder?.text("de") == "Paste…")
        #expect(action.choices?.first?.title.text("ko") == "Haiku")
    }

    @Test func actionFilesMustStayInsideTheFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("a.sh"))
        func manifest(_ run: String) -> ExtensionManifest {
            ExtensionManifest(name: "x", run: nil, actions: [.init(id: "a", title: .init("A"), run: run)])
        }
        #expect(manifest("a.sh").isRunnable(in: root))
        #expect(!manifest("../a.sh").isRunnable(in: root))
        #expect(!manifest("/bin/sh").isRunnable(in: root))
        #expect(!ExtensionManifest(name: "x", run: nil).isRunnable(in: root))
    }
}

@Suite struct ActionOutputTests {
    @Test func tellsQuestionsFromAResult() {
        #expect(ActionOutput.parse("Fix the login bug.") == .text("Fix the login bug."))
        let json = #"{"questions":[{"question":"Which screen?","options":["Login","Signup"]},{"question":"Error?"}]}"#
        #expect(ActionOutput.parse(json) == .questions([.init(question: "Which screen?", options: ["Login", "Signup"]), .init(question: "Error?", options: nil)]))
        #expect(ActionOutput.parse("```json\n" + json + "\n```") == ActionOutput.parse(json))
        // 질문이 비었거나 다른 JSON은 그냥 결과 글
        #expect(ActionOutput.parse(#"{"questions":[]}"#) == .text(#"{"questions":[]}"#))
        #expect(ActionOutput.parse(#"{"a":1}"#) == .text(#"{"a":1}"#))
        // 결과 + 메모
        #expect(ActionOutput.parse(#"{"result":"Do X.","note":"Model: Claude Haiku 5.5"}"#) == .result("Do X.", note: "Model: Claude Haiku 5.5"))
        #expect(ActionOutput.parse(#"{"result":"Do X."}"#) == .text("Do X."))
        // 메모와 함께 감싼 결과가 질문이면 질문으로
        let wrapped = #"{"result":"{\"questions\":[{\"question\":\"Which file?\"}]}","note":"Model: X"}"#
        #expect(ActionOutput.parse(wrapped) == .questions([.init(question: "Which file?", options: nil)]))
        // 질문은 세 개까지
        let many = #"{"questions":[{"question":"1"},{"question":"2"},{"question":"3"},{"question":"4"}]}"#
        if case let .questions(list) = ActionOutput.parse(many) { #expect(list.count == 3) } else { Issue.record("expected questions") }
    }
}

@Suite struct ExtensionCompatibilityTests {
    let versions = [
        CatalogVersion(version: "1.0", minKongi: "2.1.0", ref: "abc123"),
        CatalogVersion(version: "1.1", minKongi: "2.2.3"),
        CatalogVersion(version: "2.0", minKongi: "2.4.0"),
    ]

    @Test func picksTheNewestVersionThisKongiRuns() {
        #expect(ExtensionCompatibility.best(versions, on: "2.2.2")?.version == "1.0")
        #expect(ExtensionCompatibility.best(versions, on: "2.2.3")?.version == "1.1")
        #expect(ExtensionCompatibility.best(versions, on: "2.5.0")?.version == "2.0")
        #expect(ExtensionCompatibility.best(versions, on: "2.0.0") == nil)
        // 버전을 모르는 개발 빌드는 최신
        #expect(ExtensionCompatibility.best(versions, on: "0.0.0-dev")?.version == "2.0")
        #expect(ExtensionCompatibility.runs(minKongi: nil, on: "1.0"))
    }

    @Test func listsVersionsNewestFirstWithNotes() throws {
        #expect(ExtensionCompatibility.newestFirst(versions).map(\.version) == ["2.0", "1.1", "1.0"])
        let json = #"{"version":"1.2","minKongi":"2.2.3","notes":{"en":"Faster","ko":"더 빨라짐"}}"#
        let version = try JSONDecoder().decode(CatalogVersion.self, from: Data(json.utf8))
        #expect(version.notes?.text("ko") == "더 빨라짐" && version.notes?.text("fr") == "Faster")
    }

    @Test func downloadsAPinnedCommitOnlyWhenTheRefIsSafe() throws {
        let source = try #require(ExtensionSource("eocnd36/Kongi/extensions/codex"))
        #expect(source.archiveURL(ref: "abc123").absoluteString.hasSuffix("/zip/abc123"))
        #expect(source.archiveURL(ref: nil).absoluteString.hasSuffix("/zip/HEAD"))
        #expect(source.archiveURL(ref: "../x?y").absoluteString.hasSuffix("/zip/HEAD"))
    }
}

@Suite struct ExtensionPermissionTests {
    @Test func listsKnownPermissionsInOrder() {
        #expect(ExtensionManifest.knownPermissions(["network", "claude"]) == ["claude", "network"])
        #expect(ExtensionManifest.knownPermissions(["camera", "claude"]) == ["claude", "other"])
        #expect(ExtensionManifest.knownPermissions(nil).isEmpty)
    }
}

@Suite struct MultiSelectQuestionTests {
    @Test func keepsMultiSelectAndConfirm() {
        let json = #"{"questions":[{"question":"Pick","options":["A · 1 GB","B · 2 GB"],"multiSelect":true,"confirm":"Delete"}]}"#
        #expect(ActionOutput.parse(json) == .questions([.init(question: "Pick", options: ["A · 1 GB", "B · 2 GB"], multiSelect: true, confirm: "Delete")]))
    }
}
