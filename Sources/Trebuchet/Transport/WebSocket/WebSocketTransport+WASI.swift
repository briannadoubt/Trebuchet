#if os(WASI)
import Foundation
import JavaScriptEventLoop
import JavaScriptKit

/// WebSocket transport implementation for WASI/browser environments.
///
/// This implementation uses the browser's native WebSocket API via JavaScriptKit.
/// It supports client-side connect/send/receive and graceful shutdown.
/// Listening for incoming server connections is not supported in this runtime.
public final class WebSocketTransport: TrebuchetTransport, @unchecked Sendable {
    private final class HandlerSet: @unchecked Sendable {
        let onOpen: JSClosure
        let onError: JSClosure
        let onMessage: JSClosure
        let onClose: JSClosure

        init(onOpen: JSClosure, onError: JSClosure, onMessage: JSClosure, onClose: JSClosure) {
            self.onOpen = onOpen
            self.onError = onError
            self.onMessage = onMessage
            self.onClose = onClose
        }
    }

    private let lock = NSLock()
    private var sockets: [Endpoint: JSObject] = [:]
    private var handlerSets: [Endpoint: HandlerSet] = [:]
    private let incomingContinuation: AsyncStream<TransportMessage>.Continuation
    public let incoming: AsyncStream<TransportMessage>

    public init(tlsConfiguration: TLSConfiguration? = nil) {
        JavaScriptEventLoop.installGlobalExecutor()

        var continuation: AsyncStream<TransportMessage>.Continuation!
        self.incoming = AsyncStream { continuation = $0 }
        self.incomingContinuation = continuation
    }

    public func connect(to endpoint: Endpoint) async throws {
        if getSocket(for: endpoint) != nil {
            return
        }

        guard let webSocketCtor = JSObject.global.WebSocket.function else {
            throw TrebuchetError.invalidConfiguration("WebSocket API is not available in this WASI runtime")
        }

        let url = Self.urlString(for: endpoint)
        let socket = webSocketCtor.new(url)
        socket.binaryType = .string("arraybuffer")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            let lock = NSLock()

            let onOpen = JSClosure { _ in
                lock.lock()
                defer { lock.unlock() }
                if resumed { return .undefined }
                resumed = true
                continuation.resume(returning: ())
                return .undefined
            }

            let onError = JSClosure { args in
                lock.lock()
                defer { lock.unlock() }
                if resumed { return .undefined }
                resumed = true
                continuation.resume(throwing: TrebuchetError.connectionFailed(
                    host: endpoint.host,
                    port: endpoint.port,
                    underlying: JavaScriptError.message(Self.stringFromJSErrorArgs(args))
                ))
                return .undefined
            }

            let onMessage = JSClosure { [weak self] args in
                guard let self else { return .undefined }
                guard let event = args.first?.object else { return .undefined }
                let dataValue = event.data

                if let text = dataValue.string {
                    let data = Data(text.utf8)
                    let message = TransportMessage(data: data, source: endpoint, respond: { _ in })
                    self.incomingContinuation.yield(message)
                    return .undefined
                }

                if let arrayBuffer = dataValue.object {
                    guard let uint8Array = JSObject.global.Uint8Array.function?.new(arrayBuffer) else {
                        return .undefined
                    }
                    let length = Int(uint8Array.length.number ?? 0)
                    var bytes: [UInt8] = []
                    bytes.reserveCapacity(length)
                    for i in 0..<length {
                        if let byte = uint8Array[i].number {
                            bytes.append(UInt8(byte))
                        }
                    }
                    let message = TransportMessage(data: Data(bytes), source: endpoint, respond: { _ in })
                    self.incomingContinuation.yield(message)
                }

                return .undefined
            }

            let onClose = JSClosure { [weak self] _ in
                guard let self else { return .undefined }
                self.removeConnection(for: endpoint)
                return .undefined
            }

            let handlers = HandlerSet(onOpen: onOpen, onError: onError, onMessage: onMessage, onClose: onClose)

            socket.onopen = .object(onOpen)
            socket.onerror = .object(onError)
            socket.onmessage = .object(onMessage)
            socket.onclose = .object(onClose)
            self.setConnection(for: endpoint, socket: socket, handlers: handlers)
        }
    }

    public func send(_ data: Data, to endpoint: Endpoint) async throws {
        if getSocket(for: endpoint) == nil {
            try await connect(to: endpoint)
        }

        guard let socket = getSocket(for: endpoint) else {
            throw TrebuchetError.connectionFailed(host: endpoint.host, port: endpoint.port, underlying: nil)
        }

        let readyState = Int(socket.readyState.number ?? -1)
        // Browser WebSocket.OPEN = 1
        guard readyState == 1 else {
            throw TrebuchetError.connectionClosed
        }

        guard let uint8Array = JSObject.global.Uint8Array.function?.new(data.count) else {
            throw TrebuchetError.invalidConfiguration("Uint8Array constructor is unavailable in this WASI runtime")
        }
        for (index, byte) in data.enumerated() {
            uint8Array[index] = JSValue.number(Double(byte))
        }
        guard let sendFunction = socket.send.function else {
            throw TrebuchetError.invalidConfiguration("WebSocket.send is unavailable in this WASI runtime")
        }
        _ = sendFunction(this: socket, uint8Array)
    }

    public func listen(on endpoint: Endpoint) async throws {
        throw TrebuchetError.invalidConfiguration(
            "WebSocket listen is not supported on WASI/browser runtime; use connect(to:) as a client transport"
        )
    }

    public func shutdown() async {
        let connections = allConnections()
        for (_, socket) in connections {
            if let closeFunction = socket.close.function {
                _ = closeFunction(this: socket)
            }
        }
        clearAllConnections()
        incomingContinuation.finish()
    }

    private static func urlString(for endpoint: Endpoint) -> String {
        if endpoint.host.hasPrefix("ws://") || endpoint.host.hasPrefix("wss://") {
            return endpoint.host
        }
        return "ws://\(endpoint.host):\(endpoint.port)"
    }

    private static func stringFromJSErrorArgs(_ args: [JSValue]) -> String {
        guard let first = args.first else { return "WebSocket error" }
        if let text = first.string {
            return text
        }
        if let object = first.object,
           let message = object.message.string {
            return message
        }
        return "WebSocket error"
    }

    private func getSocket(for endpoint: Endpoint) -> JSObject? {
        lock.lock()
        defer { lock.unlock() }
        return sockets[endpoint]
    }

    private func setConnection(for endpoint: Endpoint, socket: JSObject, handlers: HandlerSet) {
        lock.lock()
        defer { lock.unlock() }
        sockets[endpoint] = socket
        handlerSets[endpoint] = handlers
    }

    private func removeConnection(for endpoint: Endpoint) {
        lock.lock()
        defer { lock.unlock() }
        handlerSets[endpoint] = nil
        sockets.removeValue(forKey: endpoint)
    }

    private func allConnections() -> [(Endpoint, JSObject)] {
        lock.lock()
        defer { lock.unlock() }
        return Array(sockets)
    }

    private func clearAllConnections() {
        lock.lock()
        defer { lock.unlock() }
        sockets.removeAll()
        handlerSets.removeAll()
    }
}

private enum JavaScriptError: Error, Sendable {
    case message(String)
}
#endif
