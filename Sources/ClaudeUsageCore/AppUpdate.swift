import CryptoKit
import Foundation

/// GitHub 릴리스로 앱을 업데이트할 때 쓰는 순수 로직 (버전 비교, 릴리스 해석, 서명 확인).
public enum AppUpdate {
    /// 릴리스 zip을 서명한 키의 공개 키 (Ed25519). 개인 키는 저장소 밖에 두고 릴리스 워크플로가 서명합니다.
    public static let publicKey = "wqr7m3LbKPqH6mlrz2AkFOe/MRbekBNHhRLP+/F+2og="

    /// 릴리스에서 내려받을 파일 이름 (고정)
    public static let archiveName = "Kongi.zip"
    public static let signatureName = "Kongi.zip.sig"

    public struct Release: Equatable, Sendable {
        public var version: String
        public var pageURL: URL
        public var notes: String
        public var archiveURL: URL
        public var signatureURL: URL

        public init(version: String, pageURL: URL, notes: String, archiveURL: URL, signatureURL: URL) {
            self.version = version
            self.pageURL = pageURL
            self.notes = notes
            self.archiveURL = archiveURL
            self.signatureURL = signatureURL
        }
    }

    /// `https://github.com/<owner>/<repo>` → 최신 릴리스 API 주소
    public static func latestReleaseURL(repository: URL) -> URL? {
        let parts = repository.path.split(separator: "/").map(String.init)
        guard repository.host == "github.com", parts.count >= 2 else { return nil }
        return URL(string: "https://api.github.com/repos/\(parts[0])/\(parts[1])/releases/latest")
    }

    /// GitHub `releases/latest` 응답을 해석합니다. zip과 서명 파일이 둘 다 있어야 업데이트로 봅니다.
    /// 내려받는 주소는 github.com에서만 받습니다 (응답이 엉뚱한 곳을 가리키지 못하게).
    public static func parseRelease(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = json["assets"] as? [[String: Any]] else { return nil }
        func asset(_ name: String) -> URL? {
            guard let item = assets.first(where: { $0["name"] as? String == name }),
                  let url = (item["browser_download_url"] as? String).flatMap(URL.init(string:)),
                  url.scheme == "https", url.host == "github.com" else { return nil }
            return url
        }
        guard let archive = asset(archiveName), let signature = asset(signatureName) else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard parse(version) != nil else { return nil }
        return Release(version: version, pageURL: page, notes: json["body"] as? String ?? "", archiveURL: archive, signatureURL: signature)
    }

    /// 릴리스 노트에서 바뀐 것 몇 줄: "What's new" 아래 목록의 굵은 제목 (없으면 목록 문장).
    /// `- **Automatic updates on the Mac** — …` → "Automatic updates on the Mac"
    public static func highlights(_ notes: String, limit: Int = 6) -> [String] {
        var lines = notes.components(separatedBy: .newlines)
        if let start = lines.firstIndex(where: { $0.hasPrefix("#") && $0.lowercased().contains("new") }) {
            lines = Array(lines[(start + 1)...])
            if let end = lines.firstIndex(where: { $0.hasPrefix("#") }) { lines = Array(lines[..<end]) }
        }
        var result: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 맨 앞 단계의 목록만
            guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("* "), line.first == "-" || line.first == "*" else { continue }
            var text = String(trimmed.dropFirst(2))
            if text.hasPrefix("**"), let end = text.range(of: "**", range: text.index(text.startIndex, offsetBy: 2)..<text.endIndex) {
                text = String(text[text.index(text.startIndex, offsetBy: 2)..<end.lowerBound])
            } else {
                text = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
                if let dash = text.range(of: " — ") { text = String(text[..<dash.lowerBound]) }
            }
            text = text.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { result.append(text.count > 80 ? String(text.prefix(79)) + "…" : text) }
            if result.count == limit { break }
        }
        return result
    }

    /// "2.0.1" > "2.0.0", "2.10" > "2.9". 숫자가 아닌 버전("dev")은 비교하지 않습니다.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let a = parse(candidate), let b = parse(current) else { return false }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func parse(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.count <= 4, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }
    }

    /// 내려받은 zip이 우리 키로 서명된 것인지 확인합니다. 서명 파일은 base64 한 줄입니다.
    public static func verify(_ archive: Data, signature: Data, publicKey: String = publicKey) -> Bool {
        guard let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let text = String(data: signature, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let raw = Data(base64Encoded: text) else { return false }
        return key.isValidSignature(raw, for: archive)
    }
}
