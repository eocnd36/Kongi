import Darwin
import Foundation
import Testing
@testable import ClaudeUsageCore

private func json(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

@Suite struct JSONValueTests {
    @Test func roundTripsAndKeepsIntegers() throws {
        let value = try json(#"{"a": 1, "b": [true, null, "x"], "c": 1.5}"#)
        #expect(value["a"]?.numberValue == 1)
        #expect(value["b"]?.arrayValue?.count == 3)
        let text = String(decoding: value.encodedData(), as: UTF8.self)
        #expect(text == #"{"a":1,"b":[true,null,"x"],"c":1.5}"#)
    }
}

@Suite struct HookEventTests {
    @Test func parsesPermissionRequest() throws {
        let event = HookEvent(json: try json(#"""
        { "session_id": "s1", "hook_event_name": "PermissionRequest", "cwd": "/p",
          "tool_name": "Bash", "tool_input": { "command": "rm -rf build" },
          "permission_suggestions": [{ "type": "addRules", "rules": [{ "toolName": "Bash", "ruleContent": "rm -rf build" }],
                                       "behavior": "allow", "destination": "localSettings" }] }
        """#))
        #expect(event.needsReply)
        #expect(event.permissionSuggestions.count == 1)
        #expect(event.toolInput?["command"]?.stringValue == "rm -rf build")
    }

    @Test func onlyQuestionsAndPermissionsWaitForReply() throws {
        let question = HookEvent(json: try json(#"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion"}"#))
        let bash = HookEvent(json: try json(#"{"hook_event_name":"PreToolUse","tool_name":"Bash"}"#))
        let stop = HookEvent(json: try json(#"{"hook_event_name":"Stop"}"#))
        #expect(question.needsReply)
        #expect(!bash.needsReply)
        #expect(!stop.needsReply)
        #expect(stop.wantsTerminalContext)
        #expect(!bash.wantsTerminalContext)
    }
}

@Suite struct HookReplyTests {
    @Test func allowAlwaysEchoesSuggestions() throws {
        let suggestion = try json(#"{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"ls"}],"behavior":"allow","destination":"localSettings"}"#)
        let reply = HookReplies.permission(allow: true, always: [suggestion])
        let decision = reply["hookSpecificOutput"]?["decision"]
        #expect(reply["hookSpecificOutput"]?["hookEventName"]?.stringValue == "PermissionRequest")
        #expect(decision?["behavior"]?.stringValue == "allow")
        #expect(decision?["updatedPermissions"]?.arrayValue == [suggestion])
    }

    @Test func denyCarriesMessageOnly() {
        let decision = HookReplies.permission(allow: false, message: "No")["hookSpecificOutput"]?["decision"]
        #expect(decision?["behavior"]?.stringValue == "deny")
        #expect(decision?["message"]?.stringValue == "No")
        #expect(decision?["updatedPermissions"] == nil)
    }

    @Test func answersKeepOriginalQuestions() throws {
        let input = try json(#"{"questions":[{"question":"Which?","header":"H","options":[{"label":"A"},{"label":"B"}],"multiSelect":true}]}"#)
        let reply = HookReplies.answers(toolInput: input, answers: ["Which?": AgentQuestion.answerText(["A", "B"])])
        let output = reply["hookSpecificOutput"]
        #expect(output?["permissionDecision"]?.stringValue == "allow")
        #expect(output?["updatedInput"]?["questions"] == input["questions"])
        #expect(output?["updatedInput"]?["answers"]?["Which?"]?.stringValue == "A, B")
    }
}

@Suite struct AgentQuestionTests {
    @Test func parsesQuestions() throws {
        let input = try json(#"""
        {"questions":[
          {"question":"Framework?","header":"FW","options":[{"label":"React","description":"UI"},{"label":"Vue"}],"multiSelect":false},
          {"question":"Extras?","options":[{"label":"Tests"}],"multiSelect":true},
          {"header":"no question text"}
        ]}
        """#)
        let questions = AgentQuestion.parse(input)
        #expect(questions.map(\.question) == ["Framework?", "Extras?"])
        #expect(questions[0].options.map(\.label) == ["React", "Vue"])
        #expect(questions[0].options[0].description == "UI")
        #expect(questions[1].multiSelect)
    }
}

@Suite struct ToolActivityTests {
    @Test func describesCommonTools() throws {
        #expect(ToolActivity.describe(toolName: "Edit", input: try json(#"{"file_path":"/a/b/App.swift"}"#)).target == "App.swift")
        let bash = ToolActivity.describe(toolName: "Bash", input: try json(#"{"command":"npm test\necho done"}"#))
        #expect(bash.kind == .run)
        #expect(bash.target == "npm test")
        #expect(ToolActivity.describe(toolName: "WebFetch", input: try json(#"{"url":"https://example.com/x"}"#)).target == "example.com")
        #expect(ToolActivity.describe(toolName: "mcp__github__create_issue", input: nil).toolName == "create_issue")
    }

    @Test func editedPaths() throws {
        let input = try json(#"{"file_path":"/x.txt"}"#)
        #expect(ToolActivity.editedFilePath(toolName: "Write", input: input) == "/x.txt")
        #expect(ToolActivity.editedFilePath(toolName: "Read", input: input) == nil)
    }
}

@Suite struct LineDiffTests {
    @Test func countsAndHunks() {
        let old = "a\nb\nc\nd\ne\nf\ng\nh\n"
        let new = "a\nb\nC\nd\ne\nf\ng\nh\ni\n"
        let diff = LineDiff.compute(old: old, new: new, context: 1)
        #expect(diff.added == 2)
        #expect(diff.removed == 1)
        #expect(diff.hunks.count == 2)
        #expect(diff.hunks[0].lines.map(\.kind) == [.context, .removed, .added, .context])
        #expect(diff.hunks[0].lines[1].oldNumber == 3)
        #expect(diff.hunks[0].lines[2].newNumber == 3)
    }

    @Test func newAndUnchangedFiles() {
        #expect(LineDiff.compute(old: nil, new: "x\ny").added == 2)
        #expect(LineDiff.compute(old: "same\n", new: "same\n") == .empty)
        #expect(LineDiff.compute(old: "x\n", new: nil).removed == 1)
    }
}

@Suite struct HookSettingsEditorTests {
    let command = HookSettingsEditor.command(forHelperAt: "/Users/me/Library/Application Support/ClaudeUsageBar/bin/claude-usage-hook")

    @Test func installKeepsUserHooksAndIsIdempotent() throws {
        let user: [String: Any] = [
            "model": "opus",
            "hooks": ["PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "my-check.sh"]]]]],
        ]
        let once = HookSettingsEditor.install(into: user, command: command)
        let twice = HookSettingsEditor.install(into: once, command: command)
        #expect(HookSettingsEditor.isInstalled(in: twice))
        #expect(twice["model"] as? String == "opus")
        let pre = (twice["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]]
        #expect(pre?.count == 2)
        #expect((pre?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String == "my-check.sh")
        let permission = (twice["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]]
        #expect((permission?.first?["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int == 3600)
        #expect(command.hasPrefix("\"") && command.hasSuffix("\""))
    }

    @Test func uninstallRemovesOnlyOurs() {
        let user: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": "say done"]]]]]]
        let removed = HookSettingsEditor.uninstall(from: HookSettingsEditor.install(into: user, command: command))
        let hooks = removed["hooks"] as? [String: Any]
        #expect(hooks?.keys.sorted() == ["Stop"])
        #expect(!HookSettingsEditor.isInstalled(in: removed))
        #expect(HookSettingsEditor.uninstall(from: HookSettingsEditor.install(into: [:], command: command)).isEmpty)
    }

    @Test func parsesEmptyAndSerializes() throws {
        #expect(try HookSettingsEditor.parse(nil).isEmpty)
        let data = try HookSettingsEditor.serialize(["a": 1])
        #expect(String(decoding: data, as: UTF8.self).hasSuffix("\n"))
    }
}

@Suite struct TerminalProbeTests {
    @Test func findsClaudeAncestor() {
        let rows = TerminalProbe.parse(psOutput: """
          100     1 ??       /sbin/launchd-ish
          200   100 ttys003  /bin/zsh
          300   200 ttys003  claude
          400   300 ttys003  /bin/sh
          500   400 ttys003  /Users/me/claude-usage-hook
        """)
        let found = TerminalProbe.findClaude(from: 400, in: rows)
        #expect(found?.pid == 300)
        #expect(found?.tty == "/dev/ttys003")
    }
}

@Suite struct UnixSocketTests {
    @Test func roundTrip() throws {
        let path = "/tmp/cub-test-\(getpid())-\(Int.random(in: 0...9999)).sock"
        let server = try #require(UnixSocket.listen(path: path))
        defer { close(server); unlink(path) }

        let client = try #require(UnixSocket.connect(path: path))
        defer { close(client) }
        let accepted = accept(server, nil, nil)
        defer { close(accepted) }

        #expect(UnixSocket.writeLine(client, Data("hello".utf8)))
        #expect(UnixSocket.readLine(accepted) == Data("hello".utf8))
        #expect(UnixSocket.writeLine(accepted, Data(#"{"output":null}"#.utf8)))
        #expect(UnixSocket.readLine(client) == Data(#"{"output":null}"#.utf8))
    }

    @Test func connectFailsFastWhenNobodyListens() {
        #expect(UnixSocket.connect(path: "/tmp/cub-nobody-\(getpid()).sock") == nil)
    }
}

@Suite struct PermissionRuleTests {
    @Test func keepsOnlyProjectScopedAddRules() throws {
        let suggestions = try JSONDecoder().decode([JSONValue].self, from: Data(#"""
        [ {"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"npm test"}],"behavior":"allow","destination":"localSettings"},
          {"type":"addRules","rules":[{"toolName":"Bash"}],"behavior":"allow","destination":"userSettings"},
          {"type":"setMode","mode":"bypassPermissions","destination":"session"} ]
        """#.utf8))
        #expect(PermissionRule.safeSuggestions(suggestions).count == 1)
        #expect(PermissionRule.rules(in: suggestions).map(\.text) == ["Bash(npm test)"])
    }

    @Test func rebuildsFromDisplayedRulesAndRejectsHiddenCharacters() throws {
        let suggestions = try JSONDecoder().decode([JSONValue].self, from: Data(#"""
        [ {"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"ls","extra":"x"}],"behavior":"allow","destination":"session"},
          {"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"ok"},{"toolName":"Bash","ruleContent":"rm -rf /\nls"}],"behavior":"allow","destination":"localSettings"},
          {"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"a\u202Eb"}],"behavior":"allow","destination":"localSettings"} ]
        """#.utf8))
        let safe = PermissionRule.safeSuggestions(suggestions)
        #expect(safe.count == 1)
        #expect(safe[0]["rules"]?.arrayValue?.first?["extra"] == nil)
        #expect(PermissionRule.rules(in: suggestions).map(\.text) == ["Bash(ls)"])
    }
}

@Suite struct ContinueHookTests {
    let command = HookSettingsEditor.command(forHelperAt: "/Users/me/Library/Application Support/ClaudeUsageBar/bin/claude-usage-hook")

    @Test func installsBackgroundWaitersOnStop() throws {
        let settings = HookSettingsEditor.install(into: [:], command: command)
        #expect(HookSettingsEditor.isInstalled(in: settings))
        #expect(HookSettingsEditor.canContinue(in: settings))
        let hooks = try #require(settings["hooks"] as? [String: Any])
        let waiter = try #require(HookSettingsEditor.ourHandlers(hooks, event: "StopFailure").first)
        #expect(waiter["command"] as? String == command + " --wait")
        #expect(waiter["asyncRewake"] as? Bool == true)
        #expect(waiter["timeout"] as? Int == 8 * 24 * 3600)
        // Stop에는 기본 훅과 기다리는 훅이 하나씩, 다시 설치해도 늘지 않습니다.
        let again = HookSettingsEditor.install(into: settings, command: command)
        #expect(HookSettingsEditor.ourHandlers(try #require(again["hooks"] as? [String: Any]), event: "Stop").count == 2)
        #expect(HookSettingsEditor.uninstall(from: again)["hooks"] == nil)
    }

    @Test func olderConnectionNeedsUpdate() {
        let old: [String: Any] = ["hooks": Dictionary(uniqueKeysWithValues: HookSettingsEditor.events.map { spec in
            (spec.name, [["hooks": [["type": "command", "command": command, "timeout": spec.timeout]]]] as [Any])
        })]
        #expect(HookSettingsEditor.isInstalled(in: old))
        #expect(!HookSettingsEditor.canContinue(in: old))
    }

    @Test func findsTheFolderTheConversationStartedIn() {
        let transcript = "/Users/me/.claude/projects/-Volumes-Data------Demo--/6a349c2d.jsonl"
        #expect(LaunchDirectory.encoded("/Volumes/Data/내 작업/Demo 앱") == "-Volumes-Data------Demo--")
        // 대화 중 하위 폴더로 cd 했어도 시작한 작업 영역을 찾습니다.
        #expect(LaunchDirectory.find(cwd: "/Volumes/Data/내 작업/Demo 앱/App", transcriptPath: transcript) == "/Volumes/Data/내 작업/Demo 앱")
        #expect(LaunchDirectory.find(cwd: "/Volumes/Data/내 작업/Demo 앱", transcriptPath: transcript) == "/Volumes/Data/내 작업/Demo 앱")
        #expect(LaunchDirectory.find(cwd: "/tmp/other", transcriptPath: transcript) == nil)
    }

    @Test func wakeReplyAndEnvelopeCoding() throws {
        let reply = HookReply(output: HookReplies.continuePrompt("계속해"))
        let decoded = try JSONDecoder().decode(HookReply.self, from: JSONEncoder().encode(reply))
        #expect(decoded.output?["continuePrompt"]?.stringValue == "계속해")
        // 예전 도우미가 보낸 봉투(필드 없음)도 그대로 읽힙니다.
        let plain = HookEnvelope(event: .object([:]), context: HookContext(), expectsReply: false)
        let roundTrip = try JSONDecoder().decode(HookEnvelope.self, from: JSONEncoder().encode(plain))
        #expect(roundTrip.waitsForContinue == nil)
        #expect(HookEnvelope(event: .object([:]), context: HookContext(), expectsReply: true, waitsForContinue: true).waitsForContinue == true)
    }
}

@Suite struct OriginalFileTests {
    @Test func readsOnlyRegularFilesWithinTheLimit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("of-\(UUID().uuidString).txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(OriginalFile.read(url.path).content == "hello")
        // 장치 파일은 읽지 않습니다 (끝없이 읽힘).
        let device = OriginalFile.read("/dev/zero")
        #expect(device.existed && device.content == nil)
        #expect(!OriginalFile.read("/nonexistent/\(UUID().uuidString)").existed)
    }

    @Test func doesNotBlockOnAFifo() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("fifo-\(UUID().uuidString)").path
        #expect(mkfifo(path, 0o600) == 0)
        defer { unlink(path) }
        #expect(OriginalFile.read(path).content == nil)
    }
}

@Suite struct UnixSocketOwnershipTests {
    @Test func doesNotStealALiveSocketButReplacesADeadOne() throws {
        // sun_path는 104바이트까지라 짧은 경로를 씁니다.
        let path = "/tmp/kongi-test-\(getpid()).sock"
        defer { unlink(path) }
        let first = try #require(UnixSocket.listen(path: path))
        let inode = UnixSocket.inode(path)
        #expect(UnixSocket.listen(path: path) == nil)
        #expect(UnixSocket.inode(path) == inode)
        close(first)
        // 주인이 없어진 파일은 새로 엽니다.
        let second = try #require(UnixSocket.listen(path: path))
        close(second)
    }
}
