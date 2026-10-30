// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClaudeUsageBar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ClaudeUsageBar", targets: ["ClaudeUsageBar"]),
        .executable(name: "claude-usage-hook", targets: ["ClaudeUsageHook"]),
    ],
    targets: [
        // UI 없는 순수 로직 (API 모델, 인증 정보, 포맷팅, 훅 해석) — 테스트 대상
        .target(name: "ClaudeUsageCore"),
        // 메뉴바 앱 + 아일랜드 (SwiftUI)
        .executableTarget(
            name: "ClaudeUsageBar",
            dependencies: ["ClaudeUsageCore"]
        ),
        // Claude Code 훅 도우미 (앱 번들 안에 함께 들어감)
        .executableTarget(
            name: "ClaudeUsageHook",
            dependencies: ["ClaudeUsageCore"]
        ),
        .testTarget(
            name: "ClaudeUsageCoreTests",
            dependencies: ["ClaudeUsageCore"]
        ),
    ]
)
