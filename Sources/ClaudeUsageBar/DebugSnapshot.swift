#if DEBUG
import AppKit
import ClaudeUsageCore
import SwiftUI

/// 디버그 빌드 전용: 팝오버를 PNG로 저장하고 종료합니다. README 스크린샷이나 레이아웃 확인용.
///
///   swift run ClaudeUsageBar --render-snapshot ./docs          # 내 실제 사용량
///   swift run ClaudeUsageBar --render-snapshot ./docs --demo   # 가짜 데모 데이터 (공개용)
enum DebugSnapshot {
    @MainActor
    static func runIfRequested() {
        let args = CommandLine.arguments
        // 설정 창을 열어 각 화면을 캡처합니다 (자기 창이라 화면 녹화 권한이 필요 없음).
        if let index = args.firstIndex(of: "--capture-settings"), index + 1 < args.count {
            let directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
            Task { @MainActor in
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for pane in SettingsWindow.Pane.allCases {
                    SettingsWindow.show(pane)
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    guard let window = NSApp.windows.first(where: { $0.title == "Kongi" }),
                          let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming]) else { continue }
                    let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                    try? png?.write(to: directory.appendingPathComponent("settings-\(pane.rawValue).png"))
                    print("✓ \(pane.rawValue)")
                }
                exit(0)
            }
            return
        }
        if !args.contains("--render-snapshot"), !args.contains("--render-icon") { return }
        guard let index = args.firstIndex(of: "--render-snapshot") ?? args.firstIndex(of: "--render-icon"), index + 1 < args.count else { return }
        let directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        let demo = args.contains("--demo")

        if let iconIndex = args.firstIndex(of: "--render-icon"), iconIndex + 1 < args.count {
            Task { @MainActor in
                IslandDesignPreview.renderIcon(to: URL(fileURLWithPath: args[iconIndex + 1]))
                exit(0)
            }
            return
        }
        if args.contains("--demo-video") {
            DemoStage.run(to: directory)
            return
        }
        if args.contains("--island-designs") || args.contains("--island") {
            Task { @MainActor in
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                IslandDesignPreview.render(
                    to: directory,
                    styles: args.contains("--island-designs") ? IslandStyle.allCases : [.default]
                )
                IslandDesignPreview.renderKongi(to: directory)
                IslandDesignPreview.renderMorph(to: directory)
                IslandDesignPreview.renderDynamic(to: directory.appendingPathComponent("dynamic.png"))
                IslandDesignPreview.renderIslandOnly(to: directory.appendingPathComponent("island-only.png"))
                IslandDesignPreview.renderSession(to: directory.appendingPathComponent("island-session.png"))
                exit(0)
            }
            return
        }

        Task { @MainActor in
            let store: UsageStore
            if demo {
                store = demoStore()
                // 스코어보드 예시: 진행 중인 빌드와 끝난 테스트
                for (id, name, state, fraction, passed, failed, seconds) in [
                    ("d1", "npm run build", "running", 0.64, 0, 0, 12.0),
                    ("d2", "cargo test", "succeeded", 1.0, 48, 0, 31.0),
                    ("d3", "pytest", "failed", 1.0, 41, 2, 9.0),
                ] {
                    _ = AppServices.shared.tasks.handle(.object([
                        "hook_event_name": .string("KongiTask"), "id": .string(id), "name": .string(name),
                        "cwd": .string("/Users/demo/weather-app"), "state": .string(state), "fraction": .number(fraction),
                        "passed": .number(Double(passed)), "failed": .number(Double(failed)), "seconds": .number(seconds),
                    ]))
                }
                // 확장 위젯 예시 (Codex 확장의 사용 한도)
                for (id, title, value, detail, progress) in [
                    ("codex-5h", "Codex · 5 hours", "18%", "Resets 15:40", 0.18),
                    ("codex-week", "Codex · weekly", "52%", "Resets Mon 09:00", 0.52),
                ] {
                    _ = AppServices.shared.tasks.handle(.object([
                        "hook_event_name": .string("KongiWidget"), "id": .string(id), "title": .string(title),
                        "value": .string(value), "detail": .string(detail), "progress": .number(progress),
                        "symbol": .string("gauge.with.dots.needle.50percent"),
                    ]))
                }
            } else {
                store = UsageStore()
                while store.snapshot == nil && store.error == nil {
                    try? await Task.sleep(nanoseconds: 200 * NSEC_PER_MSEC)
                }
            }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for scheme in [ColorScheme.light, .dark] {
                // ScrollView는 ImageRenderer가 그리지 못하므로 사용량 화면만 렌더링합니다.
                let view = UsageView {}
                    .frame(width: 320)
                    .environmentObject(store)
                    .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.97))
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                guard
                    let image = renderer.nsImage,
                    let tiff = image.tiffRepresentation,
                    let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
                else { continue }
                let url = directory.appendingPathComponent("popover-\(scheme == .dark ? "dark" : "light").png")
                try? png.write(to: url)
                print("✓ \(url.path)")
            }
            exit(0)
        }
    }

    @MainActor
    static func demoUsageStore() -> UsageStore { demoStore() }

    @MainActor
    private static func demoStore() -> UsageStore {
        let now = Date()
        let snapshot = UsageSnapshot(
            limits: [
                LimitItem(kind: .session, percent: 42, resetsAt: now.addingTimeInterval(2 * 3600 + 15 * 60)),
                LimitItem(kind: .weekly, percent: 63, resetsAt: now.addingTimeInterval(2 * 86400 + 5 * 3600)),
                LimitItem(kind: .weeklyOpus, percent: 91, resetsAt: now.addingTimeInterval(2 * 86400 + 5 * 3600)),
            ],
            breakdown: [
                BreakdownItem(key: "claude_code", name: "Claude Code", percent: 58),
                BreakdownItem(key: "chat", name: "Chat", percent: 35),
                BreakdownItem(key: "cowork", name: "Cowork", percent: 7),
            ],
            fetchedAt: now
        )
        return UsageStore(
            preview: snapshot,
            credentials: ClaudeCredentials(accessToken: "demo", subscriptionType: "max", rateLimitTier: "default_claude_max_5x"),
            profile: AccountProfile(email: "you@example.com", displayName: "Demo User")
        )
    }
}
#endif
