import Foundation
import Network

/// Information about the TCP connection a request arrived on.
public final class ConnectionContext: @unchecked Sendable {
    public let id: UUID
    public let peerHost: String
    public let peerPort: UInt16
    public let serverPort: UInt16
    public let openedAt: Date

    private let lock = NSLock()
    private var cachedPeer: PeerIdentity??
    private var authFailures = 0

    init(id: UUID, peerHost: String, peerPort: UInt16, serverPort: UInt16) {
        self.id = id
        self.peerHost = peerHost
        self.peerPort = peerPort
        self.serverPort = serverPort
        self.openedAt = Date()
    }

    /// Resolves (once per connection) the process on the other end of the socket.
    public func peerIdentity(resolver: PeerIdentityResolver) -> PeerIdentity? {
        lock.lock(); defer { lock.unlock() }
        if let cached = cachedPeer { return cached }
        let resolved = resolver.resolve(peerPort: peerPort, serverPort: serverPort)
        cachedPeer = .some(resolved)
        return resolved
    }

    public func recordAuthFailure() -> Int {
        lock.lock(); defer { lock.unlock() }
        authFailures += 1
        return authFailures
    }
}

/// A small HTTP/1.1 server on Network.framework, bound to loopback only.
public final class HTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest, ConnectionContext) async -> HTTPResponse

    public let host: String
    public private(set) var port: UInt16
    public let handler: Handler

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.flexpa.healthbridge.http", qos: .userInitiated)
    private let stateLock = NSLock()
    // Sessions must be retained here: Network.framework only holds the NWConnection.
    private var sessions: [UUID: ConnectionSession] = [:]
    private var onStateChange: (@Sendable (NWListener.State) -> Void)?

    /// Closes the connection after this many failed authentications.
    public var maxAuthFailuresPerConnection = 5

    public init(host: String = "127.0.0.1", port: UInt16, handler: @escaping Handler) {
        self.host = host
        self.port = port
        self.handler = handler
    }

    public var isRunning: Bool { listener?.state == .ready }

    public func start(onStateChange: (@Sendable (NWListener.State) -> Void)? = nil) throws {
        self.onStateChange = onStateChange
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.acceptLocalOnly = true
        // Bind strictly to the loopback interface. Never a wildcard address.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host),
                                                           port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener = try NWListener(using: params)
        listener.newConnectionLimit = 64
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state, let p = listener.port?.rawValue { self.port = p }
            self.onStateChange?(state)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        stateLock.lock()
        let open = Array(sessions.values)
        sessions.removeAll()
        stateLock.unlock()
        for s in open { s.close() }
    }

    public var openConnectionCount: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return sessions.count
    }

    private func accept(_ connection: NWConnection) {
        guard case .hostPort(let host, let port) = connection.endpoint else {
            connection.cancel()
            return
        }
        let hostString = "\(host)".split(separator: "%").first.map(String.init) ?? "\(host)"
        guard Self.isLoopback(hostString) else {
            connection.cancel()
            return
        }
        let ctx = ConnectionContext(id: UUID(), peerHost: hostString, peerPort: port.rawValue, serverPort: self.port)
        let session = ConnectionSession(connection: connection, context: ctx, server: self)
        stateLock.lock()
        sessions[ctx.id] = session
        let tooMany = sessions.count > 64
        stateLock.unlock()
        if tooMany {
            session.close()
            return
        }

        connection.stateUpdateHandler = { [weak session] state in
            switch state {
            case .failed, .cancelled:
                session?.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
        session.receive()
    }

    fileprivate func forget(_ id: UUID) {
        stateLock.lock()
        sessions.removeValue(forKey: id)
        stateLock.unlock()
    }

    static func isLoopback(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "::1" || host.hasPrefix("127.") || host == "::ffff:127.0.0.1" || host == "localhost"
    }
}

/// Per-connection request loop. Requests on one connection are processed serially.
private final class ConnectionSession: @unchecked Sendable {
    private let connection: NWConnection
    private let context: ConnectionContext
    private weak var server: HTTPServer?
    private var parser = HTTPRequestParser()
    private var closed = false
    private var busy = false
    private var pending: [HTTPRequest] = []
    private let lock = NSLock()

    init(connection: NWConnection, context: ConnectionContext, server: HTTPServer) {
        self.connection = connection
        self.context = context
        self.server = server
    }

    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    let out = try self.parser.feed(data)
                    if out.needsContinue {
                        self.connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                    }
                    if !out.requests.isEmpty { self.enqueue(out.requests) }
                } catch let e as HTTPParseError {
                    let status: Int
                    switch e {
                    case .bodyTooLarge: status = 413
                    case .lengthRequired: status = 411
                    default: status = 400
                    }
                    self.send(HTTPResponse.text("\(e)", status: status), keepAlive: false)
                    return
                } catch {
                    self.send(HTTPResponse.text("bad request", status: 400), keepAlive: false)
                    return
                }
            }
            if isComplete || error != nil {
                self.close()
                return
            }
            self.receive()
        }
    }

    private func enqueue(_ requests: [HTTPRequest]) {
        lock.lock()
        pending.append(contentsOf: requests)
        let shouldStart = !busy
        if shouldStart { busy = true }
        lock.unlock()
        if shouldStart { processNext() }
    }

    private func processNext() {
        lock.lock()
        guard !pending.isEmpty, let server, !closed else {
            busy = false
            lock.unlock()
            return
        }
        let request = pending.removeFirst()
        lock.unlock()
        Task { [weak self] in
            guard let self else { return }
            let response = await server.handler(request, self.context)
            let wantsClose = request.header("connection")?.lowercased() == "close" || response.status == 413 || response.status == 411
            var keepAlive = !wantsClose
            if response.status == 401 || response.status == 403 {
                if self.context.recordAuthFailure() >= server.maxAuthFailuresPerConnection { keepAlive = false }
            }
            self.send(response, keepAlive: keepAlive)
            if keepAlive { self.processNext() }
        }
    }

    private func send(_ response: HTTPResponse, keepAlive: Bool) {
        let data = response.serialize(keepAlive: keepAlive)
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            if !keepAlive { self?.close() }
        })
    }

    func close() {
        lock.lock()
        let already = closed
        closed = true
        lock.unlock()
        if already { return }
        connection.cancel()
        server?.forget(context.id)
    }
}
