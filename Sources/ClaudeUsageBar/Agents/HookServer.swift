import ClaudeUsageCore
import Darwin
import Foundation
import os

/// 훅 도우미가 보내는 이벤트를 받는 로컬 소켓 서버.
final class HookServer: @unchecked Sendable {
    private let log = Logger(subsystem: "io.github.claudeusagebar", category: "hooks")
    /// 이벤트는 받은 순서대로 처리해야 합니다 (예: 편집 전 → 편집 후). 읽기는 한 줄씩 순서대로 합니다.
    private let queue = DispatchQueue(label: "io.github.claudeusagebar.hooks")
    /// 답을 기다리는 연결의 끊김 감시용
    private let watchQueue = DispatchQueue(label: "io.github.claudeusagebar.hooks.watch", attributes: .concurrent)
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?

    /// 메인 스레드에서 불립니다. 답을 기다리는 이벤트면 connection이 함께 옵니다.
    var onEnvelope: (@MainActor (HookEnvelope, HookConnection?) -> Void)?

    @discardableResult
    func start() -> Bool {
        try? FileManager.default.createDirectory(at: HookPaths.supportDirectory, withIntermediateDirectories: true)
        guard let fd = UnixSocket.listen(path: HookPaths.socketPath) else {
            log.error("Could not listen on hook socket")
            return false
        }
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        return true
    }

    func stop() {
        source?.cancel()
        source = nil
        unlink(HookPaths.socketPath)
    }

    private func acceptClient() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        // 연결만 맺고 보내지 않는 상대 때문에 다른 이벤트가 멈추지 않도록 읽기 시간을 제한합니다.
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        // accept와 같은 순차 큐에서 바로 읽으므로 이벤트 순서가 유지됩니다.
        guard
            let line = UnixSocket.readLine(client),
            let envelope = try? JSONDecoder().decode(HookEnvelope.self, from: line)
        else {
            close(client)
            return
        }
        let connection = envelope.expectsReply ? HookConnection(fd: client, queue: watchQueue) : nil
        if connection == nil { close(client) }
        // MainActor.assumeIsolated는 macOS 14부터라 Task로 넘깁니다 (같은 스레드에서 만든 순서대로 실행됨).
        Task { @MainActor [weak self] in
            if let handler = self?.onEnvelope {
                handler(envelope, connection)
            } else {
                connection?.reply(nil)
            }
        }
    }
}

/// 답을 기다리는 훅 하나. Claude를 멈추거나(Ctrl+C) 터미널을 닫으면 연결이 끊기고 onClose가 불립니다.
final class HookConnection: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var finished = false
    private var watcher: DispatchSourceRead?

    /// 메인 스레드에서 불립니다.
    var onClose: (@MainActor () -> Void)?

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        let watcher = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        watcher.setEventHandler { [weak self] in
            guard let self else { return }
            var byte: UInt8 = 0
            if recv(fd, &byte, 1, MSG_PEEK) <= 0 { self.finish(closedByPeer: true) }
        }
        watcher.setCancelHandler { close(fd) }
        watcher.resume()
        self.watcher = watcher
    }

    /// output이 nil이면 Claude Code가 평소처럼 터미널에서 묻습니다.
    func reply(_ output: JSONValue?) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        if let data = try? JSONEncoder().encode(HookReply(output: output)) {
            UnixSocket.writeLine(fd, data)
        }
        finishLocked()
    }

    private func finish(closedByPeer: Bool) {
        lock.lock()
        let wasFinished = finished
        if !wasFinished { finishLocked() }
        lock.unlock()
        guard !wasFinished, closedByPeer else { return }
        Task { @MainActor [weak self] in self?.onClose?() }
    }

    private func finishLocked() {
        finished = true
        watcher?.cancel()
        watcher = nil
    }
}
