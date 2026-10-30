import Foundation
import Testing
@testable import ClaudeUsageCore

@Suite struct PhoneLinkTests {
    @Test func sealsAndOpensWithMatchingContext() throws {
        let cipher = try #require(PhoneCipher(keyData: PhoneCipher.newKeyData()))
        let box = try cipher.seal(Data("hello".utf8), context: PhoneCipher.requestContext)
        #expect(try cipher.open(box, context: PhoneCipher.requestContext) == Data("hello".utf8))
        let nonce = try #require(PhoneCipher.nonce(of: box))
        #expect(throws: (any Error).self) { try cipher.open(box, context: PhoneCipher.replyContext(nonce)) }
    }

    @Test func rejectsOtherKeysAndTampering() throws {
        let cipher = try #require(PhoneCipher(keyData: PhoneCipher.newKeyData()))
        let other = try #require(PhoneCipher(keyData: PhoneCipher.newKeyData()))
        var box = try cipher.seal(Data("hello".utf8), context: PhoneCipher.requestContext)
        #expect(throws: (any Error).self) { try other.open(box, context: PhoneCipher.requestContext) }
        box[box.count - 1] ^= 1
        #expect(throws: (any Error).self) { try cipher.open(box, context: PhoneCipher.requestContext) }
        #expect(PhoneCipher(keyData: Data(count: 16)) == nil)
    }

    /// 안드로이드(javax.crypto AES/GCM)와 같은 형식인지: 고정된 키·nonce로 만든 상자를 엽니다.
    @Test func opensKnownBox() throws {
        let cipher = try #require(PhoneCipher(keyData: Data(repeating: 7, count: 32)))
        let box = try #require(Data(base64Encoded: PhoneLinkFixture.box))
        #expect(try cipher.open(box, context: PhoneCipher.requestContext) == Data(#"{"t":1}"#.utf8))
    }

    @Test func replayGuardRejectsRepeatsAndOldMessages() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var guardian = ReplayGuard(notBefore: now.addingTimeInterval(-60))
        let nonce = Data([1, 2, 3])
        let first = guardian.accept(nonce: nonce, sentAt: now, now: now)
        let repeated = guardian.accept(nonce: nonce, sentAt: now, now: now.addingTimeInterval(1))
        let old = guardian.accept(nonce: Data([4]), sentAt: now.addingTimeInterval(-600), now: now)
        let fresh = guardian.accept(nonce: Data([5]), sentAt: now.addingTimeInterval(30), now: now)
        // 앱을 다시 켜기 전에 만든 요청은 nonce를 몰라도 거절합니다.
        let beforeLaunch = guardian.accept(nonce: Data([6]), sentAt: now.addingTimeInterval(-61), now: now)
        #expect(first && !repeated && !old && fresh && !beforeLaunch)
    }

    @Test func pairingRoundTrips() throws {
        let pairing = PhonePairing(id: "kongi-1a2b", name: "Demo의 MacBook", hosts: ["192.168.0.5", "10.0.0.2"], port: 47815, key: PhoneCipher.newKeyData())
        let url = try #require(pairing.url)
        #expect(url.scheme == "kongi")
        #expect(PhonePairing(url: url) == pairing)
        #expect(PhonePairing(url: URL(string: "kongi://pair?v=1&id=x&p=1&k=short")!) == nil)
        #expect(PhonePairing(url: URL(string: "https://pair?v=1")!) == nil)
    }

    @Test func onlyLocalAddressesAreLocal() {
        #expect(LocalNetwork.isLocal(ipv4: [192, 168, 0, 5]))
        #expect(LocalNetwork.isLocal(ipv4: [172, 20, 1, 1]))
        #expect(LocalNetwork.isLocal(ipv4: [10, 1, 2, 3]))
        #expect(!LocalNetwork.isLocal(ipv4: [172, 32, 1, 1]))
        #expect(!LocalNetwork.isLocal(ipv4: [8, 8, 8, 8]))
        #expect(!LocalNetwork.isLocal(ipv4: [100, 100, 1, 1]))
        #expect(LocalNetwork.isLocal(ipv6: [0xfe, 0x80] + [UInt8](repeating: 0, count: 13) + [1]))
        #expect(LocalNetwork.isLocal(ipv6: [UInt8](repeating: 0, count: 10) + [0xff, 0xff, 192, 168, 1, 2]))
        #expect(!LocalNetwork.isLocal(ipv6: [0x20, 0x01] + [UInt8](repeating: 0, count: 14)))
    }
}

/// 안드로이드 앱의 PhoneCipherTest가 같은 키(7 × 32), nonce(0…11), 내용으로 만든 상자
enum PhoneLinkFixture {
    static let box = "AAECAwQFBgcICQoLY6OdUic4pH0N10v2jf6fuKBwoL+Siu0="
}
