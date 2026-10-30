import ClaudeUsageCore
import Foundation
import Network
import os

/// 안드로이드 앱용 HTTP 서버. 같은 Wi-Fi(사설망) 안의 기기만 받고, 내용은 MobileBridge가 봉인·확인합니다.
/// Bonjour로 자신을 알려서 Mac의 IP가 바뀌어도 휴대폰이 다시 찾습니다.
final class MobileServer: @unchecked Sendable {
    static let port: UInt16 = 47815

    private let queue = DispatchQueue(label: "io.github.claudeusagebar.mobile")
    private var listener: NWListener?
    private let log = Logger(subsystem: "io.github.claudeusagebar", category: "mobile")

    /// 메인 스레드에서 불립니다.
    var onRequest: (@MainActor (HTTPRequest, MobileConnection) -> Void)?
    /// 포트를 실제로 잡았을 때 true, 못 잡았거나(이미 사용 중 등) 닫혔을 때 false. 메인 스레드에서 불립니다.
    var onReadyChange: (@MainActor (Bool) -> Void)?

    func start(serviceName: String) throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        // 재시작 직후 TIME_WAIT 때문에 못 여는 일을 막습니다. 듣고 있는 동안 다른 프로세스가 같은 포트를 함께 열 수는 없습니다 (SO_REUSEPORT로도 확인).
        parameters.allowLocalEndpointReuse = true
        // VPN·셀룰러 같은 바깥 인터페이스는 받지 않습니다.
        parameters.prohibitedInterfaceTypes = [.cellular]
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.port)!)
        listener.service = NWListener.Service(name: serviceName, type: PhonePairing.serviceType)
        listener.serviceRegistrationUpdateHandler = { [log] change in
            log.info("Bonjour: \(String(describing: change), privacy: .public)")
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        // 포트를 못 잡은 경우는 start()에서 던져지지 않고 여기로만 알려집니다.
        listener.stateUpdateHandler = { [weak self] state in
            let ready: Bool
            switch state {
            case .ready: ready = true
            case .waiting, .failed, .cancelled:
                self?.log.error("Phone listener: \(String(describing: state), privacy: .public)")
                ready = false
            default: return
            }
            Task { @MainActor [weak self] in self?.onReadyChange?(ready) }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        guard Self.isLocalPeer(connection.endpoint) else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private static func isLocalPeer(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case let .ipv4(address): return LocalNetwork.isLocal(ipv4: [UInt8](address.rawValue))
        case let .ipv6(address): return LocalNetwork.isLocal(ipv6: [UInt8](address.rawValue))
        default: return false
        }
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequest.parse(buffer) {
            case let .complete(request):
                let client = MobileConnection(connection: connection)
                Task { @MainActor [weak self] in
                    if let handler = self?.onRequest {
                        handler(request, client)
                    } else {
                        client.respond(.text("Unavailable", status: 503))
                    }
                }
            case .invalid:
                MobileConnection(connection: connection).respond(.text("Bad Request", status: 400))
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            }
        }
    }
}

/// 요청 하나. 일반 응답을 보내거나, 실시간 업데이트(Server-Sent Events) 스트림으로 바꿀 수 있습니다.
final class MobileConnection: @unchecked Sendable {
    let connection: NWConnection
    private(set) var isStreaming = false
    var onClose: (@MainActor () -> Void)?

    init(connection: NWConnection) {
        self.connection = connection
    }

    func respond(_ response: HTTPResponse) {
        connection.send(content: response.serialized(), completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
    }

    func startStream() {
        isStreaming = true
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: keep-alive\r\nX-Accel-Buffering: no\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor [weak self] in self?.onClose?() }
            default:
                break
            }
        }
        // 상대가 끊으면 receive가 끝납니다.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil { self?.connection.cancel() }
        }
    }

    func send(event: String, data: String) {
        let lines = data.split(separator: "\n", omittingEmptySubsequences: false).map { "data: \($0)" }.joined(separator: "\n")
        connection.send(content: Data("event: \(event)\n\(lines)\n\n".utf8), completion: .contentProcessed { _ in })
    }

    func ping() {
        connection.send(content: Data(": ping\n\n".utf8), completion: .contentProcessed { _ in })
    }
}
