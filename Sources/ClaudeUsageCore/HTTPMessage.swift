import Foundation

/// 안드로이드 앱을 위한 아주 작은 HTTP/1.1 구현 (같은 Wi-Fi 안에서만 열리고, 본문은 PhoneCipher로 봉인됨).
public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// 소문자 키
    public var headers: [String: String]
    public var body: Data

    public enum ParseResult: Equatable {
        case incomplete
        case invalid
        case complete(HTTPRequest)
    }

    public static let maxBodySize = 1_000_000

    public static func parse(_ data: Data) -> ParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = data.range(of: separator) else {
            return data.count > 64 * 1024 ? .invalid : .incomplete
        }
        guard let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length >= 0, length <= maxBodySize else { return .invalid }
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= length else { return .incomplete }

        let target = String(requestLine[1])
        let components = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return .complete(HTTPRequest(
            method: String(requestLine[0]).uppercased(),
            path: components?.path ?? target,
            query: query,
            headers: headers,
            body: data[bodyStart..<(bodyStart + length)]
        ))
    }

}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json(_ value: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store"], body: data)
    }

    public static func text(_ text: String, status: Int) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(text.utf8))
    }

    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        var all = headers
        all["Content-Length"] = String(body.count)
        all["Connection"] = "close"
        all["X-Content-Type-Options"] = "nosniff"
        for (name, value) in all.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        default: return "Error"
        }
    }

    public static func contentType(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "webmanifest": return "application/manifest+json"
        case "png": return "image/png"
        case "svg": return "image/svg+xml"
        default: return "application/octet-stream"
        }
    }
}
