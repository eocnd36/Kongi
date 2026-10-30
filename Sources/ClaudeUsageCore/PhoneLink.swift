import CryptoKit
import Foundation

/// 안드로이드 앱과 Mac 사이의 메시지 봉인 (AES-GCM).
///
/// 같은 Wi-Fi 안에서 평문 HTTP로 오가므로, 요청·응답·실시간 업데이트 모두 QR 코드로 나눈 키로 암호화합니다.
/// 키가 없으면 내용을 볼 수도, 요청을 만들 수도 없습니다. 상자 형식은 nonce(12) | 암호문 | 태그(16)입니다.
public struct PhoneCipher: Sendable {
    public static let keySize = 32
    static let nonceSize = 12

    /// 상자마다 붙이는 용도 표시. 다른 용도의 상자를 바꿔 끼우지 못하게 합니다.
    public static let requestContext = Data("kongi.request.v1".utf8)
    public static func replyContext(_ requestNonce: Data) -> Data { Data("kongi.reply.v1".utf8) + requestNonce }
    public static func eventContext(_ requestNonce: Data) -> Data { Data("kongi.event.v1".utf8) + requestNonce }

    private let key: SymmetricKey

    public init?(keyData: Data) {
        guard keyData.count == Self.keySize else { return nil }
        key = SymmetricKey(data: keyData)
    }

    public static func newKeyData() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    public func seal(_ plaintext: Data, context: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(plaintext, using: key, authenticating: context).combined else {
            throw CryptoKitError.incorrectParameterSize
        }
        return combined
    }

    public func open(_ box: Data, context: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: box), using: key, authenticating: context)
    }

    public static func nonce(of box: Data) -> Data? {
        box.count > nonceSize + 16 ? Data(box.prefix(nonceSize)) : nil
    }
}

/// 같은 요청을 다시 흘려보내는 공격을 막습니다. 보낸 시각이 너무 다르거나 이미 받은 nonce면 거절합니다.
///
/// 받은 nonce는 메모리에만 있으므로, 앱을 다시 켠 직후 예전 요청을 다시 받지 않도록
/// `notBefore`(만든 시각)보다 앞선 요청은 모두 거절합니다.
public struct ReplayGuard: Sendable {
    public var window: TimeInterval = 120
    public let notBefore: Date
    private var seen: [Data: Date] = [:]

    public init(notBefore: Date = Date()) {
        self.notBefore = notBefore
    }

    public mutating func accept(nonce: Data, sentAt: Date, now: Date = Date()) -> Bool {
        guard sentAt >= notBefore, abs(sentAt.timeIntervalSince(now)) <= window else { return false }
        seen = seen.filter { now.timeIntervalSince($0.value) <= window * 2 }
        guard seen[nonce] == nil else { return false }
        seen[nonce] = now
        return true
    }
}

/// QR 코드에 담는 연결 정보. 휴대폰 기본 카메라로 찍으면 Kongi 앱이 열립니다.
///
/// kongi://pair?v=1&id=<Mac 식별자>&n=<Mac 이름>&h=<IP,IP>&p=<포트>&k=<키>
public struct PhonePairing: Equatable, Sendable {
    public static let scheme = "kongi"
    /// Bonjour 서비스 종류. Mac의 IP가 바뀌어도 휴대폰이 다시 찾습니다.
    public static let serviceType = "_kongi._tcp"

    public var id: String
    public var name: String
    public var hosts: [String]
    public var port: UInt16
    public var key: Data

    public init(id: String, name: String, hosts: [String], port: UInt16, key: Data) {
        self.id = id
        self.name = name
        self.hosts = hosts
        self.port = port
        self.key = key
    }

    public var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "n", value: name),
            URLQueryItem(name: "h", value: hosts.joined(separator: ",")),
            URLQueryItem(name: "p", value: String(port)),
            URLQueryItem(name: "k", value: Base64URL.encode(key)),
        ]
        return components.url
    }

    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == Self.scheme, components.host == "pair" else { return nil }
        let items = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard items["v"] == "1", let id = items["id"], !id.isEmpty,
              let port = items["p"].flatMap(UInt16.init),
              let key = items["k"].flatMap(Base64URL.decode), key.count == PhoneCipher.keySize else { return nil }
        self.init(
            id: id,
            name: items["n"] ?? "",
            hosts: (items["h"] ?? "").split(separator: ",").map(String.init),
            port: port,
            key: key
        )
    }
}

public enum LocalNetwork {
    /// 휴대폰이 들어올 수 있는 주소인지: 사설망, 링크 로컬, 루프백만 허용합니다.
    public static func isLocal(ipv4 bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        switch (bytes[0], bytes[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    public static func isLocal(ipv6 bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes == [UInt8](repeating: 0, count: 15) + [1] { return true }
        // IPv4가 섞인 주소 (::ffff:a.b.c.d)
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            return isLocal(ipv4: Array(bytes[12..<16]))
        }
        // fe80::/10 링크 로컬, fc00::/7 고유 로컬
        return (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) || bytes[0] & 0xfe == 0xfc
    }
}

public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ string: String) -> Data? {
        var text = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text.append("=") }
        return Data(base64Encoded: text)
    }
}
