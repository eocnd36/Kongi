import Foundation
import Testing
@testable import ClaudeUsageCore

@Suite struct EditPreviewTests {
    @Test func editReplacesFirstOrAll() {
        let original = "a = 1\nb = 1\n"
        let edit: JSONValue = .object(["old_string": .string("= 1"), "new_string": .string("= 2")])
        #expect(EditPreview.predictedContent(toolName: "Edit", input: edit, original: original) == "a = 2\nb = 1\n")
        let all: JSONValue = .object(["old_string": .string("= 1"), "new_string": .string("= 2"), "replace_all": .bool(true)])
        #expect(EditPreview.predictedContent(toolName: "Edit", input: all, original: original) == "a = 2\nb = 2\n")
        // 찾는 글자가 없으면 미리 보기를 만들지 않습니다.
        let missing: JSONValue = .object(["old_string": .string("zzz"), "new_string": .string("y")])
        #expect(EditPreview.predictedContent(toolName: "Edit", input: missing, original: original) == nil)
    }

    @Test func multiEditAndWrite() throws {
        let input: JSONValue = .object(["edits": .array([
            .object(["old_string": .string("one"), "new_string": .string("1")]),
            .object(["old_string": .string("two"), "new_string": .string("2")]),
        ])])
        #expect(EditPreview.predictedContent(toolName: "MultiEdit", input: input, original: "one two") == "1 2")
        let diff = try #require(EditPreview.diff(toolName: "Write", input: .object(["content": .string("x\ny\n")]), original: nil))
        #expect(diff.added == 2 && diff.removed == 0)
        #expect(EditPreview.diff(toolName: "Read", input: nil, original: "x") == nil)
    }

    @Test func limitsLongDiffs() {
        let new = (1...200).map { "line \($0)" }.joined(separator: "\n")
        let limited = LineDiff.compute(old: nil, new: new).limited(maxLines: 30)
        #expect(limited.hunks.flatMap(\.lines).count == 30)
        #expect(limited.truncated)
        #expect(limited.added == 200)
    }
}

@Suite struct TranscriptReaderTests {
    func write(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func readsOnlyClaudesTextAndContinuesFromOffset() throws {
        let url = try write([
            #"{"type":"user","message":{"content":"hi"},"uuid":"u1"}"#,
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-10-29T01:02:03.000Z","message":{"content":[{"type":"thinking","thinking":"x"}]}}"#,
            #"{"type":"assistant","uuid":"a2","timestamp":"2026-10-29T01:02:04.000Z","message":{"content":[{"type":"text","text":"Looking at the code."}]}}"#,
            #"{"type":"assistant","uuid":"a3","isSidechain":true,"message":{"content":[{"type":"text","text":"subagent"}]}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let first = TranscriptReader.read(url, from: nil)
        #expect(first.messages.map(\.text) == ["hi", "Looking at the code."])
        #expect(first.messages.map(\.role) == [.user, .assistant])
        #expect(first.messages.last?.id == "a2")
        // 아무것도 안 늘었으면 빈 결과, 새 줄이 붙으면 그것만
        #expect(TranscriptReader.read(url, from: first.offset).messages.isEmpty)
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data((#"{"type":"assistant","uuid":"a4","message":{"content":[{"type":"text","text":"Done."}]}}"# + "\n").utf8))
        try handle.close()
        #expect(TranscriptReader.read(url, from: first.offset).messages.map(\.text) == ["Done."])
    }

    @Test func keepsOnlyWhatTheUserTyped() throws {
        let url = try write([
            #"{"type":"user","uuid":"u1","message":{"content":[{"type":"text","text":"<ide_selection>code</ide_selection>"},{"type":"text","text":"Fix the bug<system-reminder>ignore</system-reminder>"}]}}"#,
            #"{"type":"user","uuid":"u2","isMeta":true,"message":{"content":"meta"}}"#,
            #"{"type":"user","uuid":"u3","message":{"content":[{"type":"tool_result","content":"x"}]}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(TranscriptReader.read(url, from: nil).messages.map(\.text) == ["Fix the bug"])
    }

    @Test func tellsWhetherTheTurnEnded() throws {
        let working = try write([
            #"{"type":"assistant","timestamp":"2026-10-29T05:29:46.000Z","message":{"stop_reason":"tool_use","content":[{"type":"tool_use"}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: working) }
        #expect(TranscriptReader.readWithTurn(working, from: nil).turn == .continuing)

        let ended = try write([
            #"{"type":"assistant","timestamp":"2026-10-29T05:29:46.000Z","message":{"stop_reason":"tool_use","content":[]}}"#,
            #"{"type":"assistant","timestamp":"2026-10-29T05:30:01.000Z","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"Done."}]}}"#,
            #"{"type":"system","subtype":"x"}"#,
        ])
        defer { try? FileManager.default.removeItem(at: ended) }
        guard case .ended? = TranscriptReader.readWithTurn(ended, from: nil).turn else {
            Issue.record("expected ended"); return
        }

        let stopped = try write([
            #"{"type":"assistant","message":{"stop_reason":"tool_use","content":[]}}"#,
            #"{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: stopped) }
        guard case .interrupted? = TranscriptReader.readWithTurn(stopped, from: nil).turn else {
            Issue.record("expected interrupted"); return
        }
    }

    @Test func ignoresAPartialLastLine() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("partial-\(UUID().uuidString).jsonl")
        try Data(#"{"type":"assistant","uuid":"a1","message":{"content":[{"type":"text","text":"half"#.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = TranscriptReader.read(url, from: 0)
        #expect(result.messages.isEmpty)
        #expect(result.offset == 0)
    }
}

@Suite struct CodexTranscriptTests {
    @Test func readsCodexMessagesAndTurns() throws {
        let lines = [
            #"{"timestamp":"2026-11-11T04:31:11.333Z","type":"event_msg","payload":{"type":"user_message","message":"fix the build"}}"#,
            #"{"timestamp":"2026-11-11T04:31:12.000Z","type":"response_item","payload":{"type":"reasoning"}}"#,
            #"{"timestamp":"2026-11-11T04:31:14.588Z","type":"event_msg","payload":{"type":"agent_message","message":"Done.","phase":"final"}}"#,
            #"{"timestamp":"2026-11-11T04:33:44.153Z","type":"event_msg","payload":{"type":"task_complete"}}"#,
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("codex-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = TranscriptReader.readWithTurn(url, from: nil)
        #expect(result.messages.map(\.text) == ["fix the build", "Done."])
        #expect(result.messages.map(\.role) == [.user, .assistant])
        if case .ended = result.turn {} else { Issue.record("turn should be ended") }
        // 다시 읽어도 id가 같아야 중복되지 않습니다.
        #expect(TranscriptReader.readWithTurn(url, from: nil).messages.map(\.id) == result.messages.map(\.id))
    }

    @Test func tracksTheFileACodexPatchEdits() {
        let input: JSONValue = .object(["command": .string("*** Begin Patch\n*** Update File: src/a.swift\n@@\n-x\n+y\n*** End Patch")])
        #expect(ToolActivity.editedFilePath(toolName: "apply_patch", input: input) == "src/a.swift")
    }
}
