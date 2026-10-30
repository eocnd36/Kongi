import Darwin
import Foundation

/// 훅 도우미와 앱이 주고받는 로컬 소켓 (한 줄 = JSON 하나). 같은 사용자만 접근할 수 있게 권한을 600으로 둡니다.
public enum UnixSocket {
    private static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }

    /// 앱이 꺼져 있으면 바로 nil을 돌려줍니다 (Claude Code를 기다리게 하지 않음).
    public static func connect(path: String) -> Int32? {
        guard var address = address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    public static func listen(path: String) -> Int32? {
        unlink(path)
        guard var address = address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 32) == 0 else {
            close(fd)
            return nil
        }
        chmod(path, 0o600)
        return fd
    }

    @discardableResult
    public static func writeLine(_ fd: Int32, _ data: Data) -> Bool {
        var payload = data
        payload.append(0x0A)
        return payload.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }

    /// 줄바꿈이 올 때까지 읽습니다. 상대가 연결을 끊으면 nil.
    public static func readLine(_ fd: Int32, limit: Int = 16 * 1024 * 1024) -> Data? {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while result.count < limit {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { return result.isEmpty ? nil : result }
            if let newline = buffer[0..<count].firstIndex(of: 0x0A) {
                result.append(contentsOf: buffer[0..<newline])
                return result
            }
            result.append(contentsOf: buffer[0..<count])
        }
        return nil
    }
}
