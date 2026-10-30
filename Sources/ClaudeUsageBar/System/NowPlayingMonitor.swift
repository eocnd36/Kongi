import AppKit
import os

/// 지금 재생 중인 음악 (Apple Music, Spotify).
/// macOS는 다른 앱의 "지금 재생 중" 정보를 일반 앱에 공개하지 않아서, 각 앱의 AppleScript로 읽습니다.
/// 실행 중인 앱만 묻기 때문에 꺼져 있는 음악 앱을 켜지 않습니다. 처음 한 번은 "Kongi가 Music을 제어" 허용을 묻습니다.
@MainActor
final class NowPlayingMonitor: ObservableObject {
    struct Track: Equatable {
        var title: String
        var artist: String
        var isPlaying: Bool
        /// 초
        var position: Double
        var duration: Double
        var app: Player
        var artwork: NSImage?
        /// position을 읽은 시각
        var readAt = Date()

        /// 지금 재생 위치 (재생 중이면 지난 시간만큼 더함)
        func position(at date: Date) -> Double {
            isPlaying ? min(position + date.timeIntervalSince(readAt), duration) : position
        }

        static func == (lhs: Track, rhs: Track) -> Bool {
            // 재생 위치는 비교하지 않습니다 (계속 바뀌어 화면을 다시 그리게 함). 크게 어긋났을 때만 다르게 봅니다.
            lhs.title == rhs.title && lhs.artist == rhs.artist && lhs.isPlaying == rhs.isPlaying
                && abs(lhs.position(at: Date()) - rhs.position(at: Date())) < 3
                && lhs.app == rhs.app && (lhs.artwork == nil) == (rhs.artwork == nil)
        }
    }

    enum Player: String {
        case music = "com.apple.Music"
        case spotify = "com.spotify.client"

        var scriptName: String { self == .music ? "Music" : "Spotify" }
    }

    @Published private(set) var track: Track?

    private var task: Task<Void, Never>?
    private var artworkKey: String?
    private var observers: [NSObjectProtocol] = []
    /// 한 번 컴파일한 스크립트는 다시 씁니다 (매번 컴파일하면 느리고 시스템 검사도 매번 돕니다).
    private var scripts: [String: NSAppleScript] = [:]
    private let log = Logger(subsystem: "io.github.claudeusagebar", category: "nowplaying")

    /// 곡이 바뀌거나 재생·일시정지하면 Music과 Spotify가 알려 주므로(분산 알림) 그때 바로 읽습니다.
    /// 재생 위치만 맞추려고 재생 중일 때 가끔 확인합니다.
    func setActive(_ active: Bool) {
        if active {
            guard task == nil else { return }
            let center = DistributedNotificationCenter.default()
            for name in ["com.apple.Music.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
                observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.poll() }
                })
            }
            task = Task { [weak self] in
                while !Task.isCancelled {
                    self?.poll()
                    // 바뀌면 알림이 오므로, 이건 놓친 것을 잡는 안전망입니다.
                    try? await Task.sleep(nanoseconds: 30 * NSEC_PER_SEC)
                }
            }
        } else {
            task?.cancel()
            task = nil
            observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
            observers.removeAll()
            track = nil
        }
    }

    private func isRunning(_ player: Player) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: player.rawValue).isEmpty
    }

    private func poll() {
        // 재생 중인 쪽을 우선, 둘 다 멈춰 있으면 마지막으로 본 것을 잠시 보여 줍니다.
        var found: Track?
        for player in [Player.spotify, .music] where isRunning(player) {
            guard let track = read(player) else { continue }
            if track.isPlaying { found = track; break }
            if found == nil { found = track }
        }
        guard var found else {
            track = nil
            return
        }
        let key = "\(found.app.rawValue)|\(found.title)|\(found.artist)"
        if key == artworkKey, let artwork = track?.artwork {
            found.artwork = artwork
        } else {
            artworkKey = key
            if found.app == .music {
                found.artwork = musicArtwork()
            } else {
                loadSpotifyArtwork(key: key)
            }
        }
        if track != found { track = found }
    }

    private func read(_ player: Player) -> Track? {
        let duration = player == .spotify ? "((duration of current track) / 1000)" : "(duration of current track)"
        let source = """
        tell application "\(player.scriptName)"
            if player state is stopped then return ""
            set s to (player state as string)
            return (name of current track) & "\u{1F}" & (artist of current track) & "\u{1F}" & s & "\u{1F}" & (player position as string) & "\u{1F}" & (\(duration) as string)
        end tell
        """
        guard let text = run(source), !text.isEmpty else { return nil }
        let parts = text.components(separatedBy: "\u{1F}")
        guard parts.count >= 5 else { return nil }
        func number(_ text: String) -> Double { Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        return Track(
            title: parts[0], artist: parts[1], isPlaying: parts[2] == "playing",
            position: number(parts[3]), duration: number(parts[4]), app: player, artwork: nil
        )
    }

    private func loadSpotifyArtwork(key: String) {
        guard let url = run("tell application \"Spotify\" to return artwork url of current track").flatMap(URL.init(string:)) else { return }
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) else { return }
            guard let self, self.artworkKey == key else { return }
            self.track?.artwork = image
        }
    }

    private func musicArtwork() -> NSImage? {
        var error: NSDictionary?
        guard let descriptor = script("tell application \"Music\" to return raw data of artwork 1 of current track")?
            .executeAndReturnError(&error), error == nil else { return nil }
        return NSImage(data: descriptor.data)
    }

    private func script(_ source: String) -> NSAppleScript? {
        if let cached = scripts[source] { return cached }
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        script.compileAndReturnError(&error)
        scripts[source] = script
        return script
    }

    #if DEBUG
    func setPreview(_ track: Track?) { self.track = track }
    #endif

    func playPause() { control("playpause") }
    func next() { control("next track") }
    func previous() { control("previous track") }

    private func control(_ command: String) {
        guard let player = track?.app else { return }
        _ = run("tell application \"\(player.scriptName)\" to \(command)")
        poll()
    }

    private func run(_ source: String) -> String? {
        var error: NSDictionary?
        let result = script(source)?.executeAndReturnError(&error)
        if let error {
            log.debug("Now playing script failed: \(error, privacy: .public)")
            return nil
        }
        return result?.stringValue
    }
}
