import Foundation
import Network

/// Listens on 127.0.0.1:<port> and parses a newline-delimited JSON stream of
/// WireFrame messages produced by `coder-bar-hook` invocations.
public final class EventServer: @unchecked Sendable {
    private let listener: NWListener
    private let handler: @Sendable (HookPayload) -> Void
    private let onReady: @Sendable (UInt16) -> Void

    public init(port: UInt16,
                handler: @escaping @Sendable (HookPayload) -> Void,
                onReady: @escaping @Sendable (UInt16) -> Void = { _ in }) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port)!
        )
        self.listener = try NWListener(using: params)
        self.handler = handler
        self.onReady = onReady
    }

    public var port: UInt16 {
        listener.port?.rawValue ?? 0
    }

    public func start() {
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let port = self?.listener.port?.rawValue {
                    self?.onReady(port)
                }
            case .failed(let err):
                NSLog("EventServer failed: \(err)")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener.start(queue: DispatchQueue(label: "coder-bar-listener"))
    }

    public func stop() {
        listener.cancel()
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: DispatchQueue(label: "coder-bar-conn"))
        receiveLoop(conn, buffer_: Data())
    }

    private func receiveLoop(_ conn: NWConnection, buffer_ initial: Data) {
        var buffer = initial
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                buffer.append(data)
            }
            let lines = buffer.split(separator: 0x0A)
            if lines.count > 1 {
                buffer = Data(lines.last ?? Data())
                let complete = lines.dropLast()
                for line in complete {
                    self?.parse(Data(line))
                }
            }
            if let error {
                NSLog("hook connection error: \(error)")
                return
            }
            if isComplete {
                self?.parse(buffer)
                return
            }
            self?.receiveLoop(conn, buffer_: buffer)
        }
    }

    private func parse(_ data: Data) {
        guard let frame = try? JSONDecoder().decode(WireFrame.self, from: data) else {
            return
        }
        guard let raw = frame.payload else { return }
        var payload = HookPayload.wrap(source: frame.source, category: frame.category, payload: raw)
        if payload.source == nil {
            if let s = frame.source, !s.isEmpty { payload.source = s }
            else if let s = raw["source"]?.stringValue { payload.source = s }
        }
        if payload.category == nil {
            payload.category = frame.category ?? raw["category"]?.stringValue
        }
        if payload.hookEventName == nil {
            payload.hookEventName = raw["hookEventName"]?.stringValue ?? payload.category ?? payload.hookMessageName
        }
        handler(payload)
    }
}