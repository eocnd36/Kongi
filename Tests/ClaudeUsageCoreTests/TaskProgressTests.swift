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
