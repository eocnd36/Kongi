import CryptoKit
import Foundation
import Testing
@testable import ClaudeUsageCore

@Suite struct AppUpdateTests {
    @Test func comparesVersions() {
        #expect(AppUpdate.isNewer("2.0.1", than: "2.0.0"))
        #expect(AppUpdate.isNewer("2.10", than: "2.9.9"))
        #expect(AppUpdate.isNewer("3", than: "2.9"))
        #expect(!AppUpdate.isNewer("2.0.0", than: "2.0"))
        #expect(!AppUpdate.isNewer("1.9", than: "2.0.0"))
        #expect(!AppUpdate.isNewer("2.1.0", than: "dev"))
        #expect(!AppUpdate.isNewer("beta", than: "2.0.0"))
    }

    @Test func findsTheLatestReleaseURL() {
        #expect(AppUpdate.latestReleaseURL(repository: URL(string: "https://github.com/eocnd36/Kongi")!)?.absoluteString
                == "https://api.github.com/repos/eocnd36/Kongi/releases/latest")
        #expect(AppUpdate.latestReleaseURL(repository: URL(string: "https://example.com/a/b")!) == nil)
    }

    private func releaseJSON(tag: String = "v2.0.1", host: String = "github.com", withSignature: Bool = true, prerelease: Bool = false) -> Data {
        var assets: [[String: Any]] = [["name": "Kongi.zip", "browser_download_url": "https://\(host)/eocnd36/Kongi/releases/download/\(tag)/Kongi.zip"]]
        if withSignature {
            assets.append(["name": "Kongi.zip.sig", "browser_download_url": "https://\(host)/eocnd36/Kongi/releases/download/\(tag)/Kongi.zip.sig"])
        }
        let json: [String: Any] = ["tag_name": tag, "html_url": "https://github.com/eocnd36/Kongi/releases/tag/\(tag)",
                                   "body": "Notes", "draft": false, "prerelease": prerelease, "assets": assets]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    @Test func parsesReleases() throws {
        let release = try #require(AppUpdate.parseRelease(releaseJSON()))
        #expect(release.version == "2.0.1")
        #expect(release.archiveURL.lastPathComponent == "Kongi.zip")
        #expect(release.signatureURL.lastPathComponent == "Kongi.zip.sig")
        // 서명이 없거나, 다른 곳을 가리키거나, 미리 보기 릴리스면 업데이트로 보지 않습니다.
        #expect(AppUpdate.parseRelease(releaseJSON(withSignature: false)) == nil)
        #expect(AppUpdate.parseRelease(releaseJSON(host: "evil.example")) == nil)
        #expect(AppUpdate.parseRelease(releaseJSON(prerelease: true)) == nil)
        #expect(AppUpdate.parseRelease(releaseJSON(tag: "nightly")) == nil)
    }

    @Test func verifiesSignatures() {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let archive = Data("zip bytes".utf8)
        let signature = Data((try! key.signature(for: archive)).base64EncodedString().utf8)
        #expect(AppUpdate.verify(archive, signature: signature, publicKey: publicKey))
        #expect(!AppUpdate.verify(Data("other bytes".utf8), signature: signature, publicKey: publicKey))
        #expect(!AppUpdate.verify(archive, signature: signature))  // 다른 키 (앱에 든 키)
        #expect(!AppUpdate.verify(archive, signature: Data("not base64".utf8), publicKey: publicKey))
    }
}
