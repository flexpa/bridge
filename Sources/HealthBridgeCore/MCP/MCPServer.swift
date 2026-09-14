import Foundation

public enum BridgeInfo {
    public static let name = "health-bridge"
    public static let displayName = "Flexpa Health Bridge"
    public static let version = "0.1.0"
    public static let mcpPath = "/mcp"
    public static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    public static let latestProtocolVersion = "2025-06-18"
}

struct MCPSession: Sendable {
    var id: String
    var pairingID: UUID
    var protocolVersion: String
    var clientName: String?
    var createdAt: Date
}

/// Streamable-HTTP MCP endpoint: authenticates the caller, validates the
/// request came from a loopback client, and dispatches JSON-RPC.
public final class MCPServer: @unchecked Sendable {
    public typealias ProviderSource = @Sendable () -> HealthDataProvider
    public typealias SettingsSource = @Sendable () -> BridgeSettings

    private let providerSource: ProviderSource
    private let settingsSource: SettingsSource
    private let pairings: PairingStore
    private let audit: AuditLog
    private let peerResolver: PeerIdentityResolver?

    private let sessionLock = NSLock()
    private var sessions: [String: MCPSession] = [:]

    public init(provider: @escaping ProviderSource, settings: @escaping SettingsSource, pairings: PairingStore,
                audit: AuditLog, peerResolver: PeerIdentityResolver? = LibprocPeerResolver()) {
        self.providerSource = provider
        self.settingsSource = settings
        self.pairings = pairings
        self.audit = audit
        self.peerResolver = peerResolver
    }

    // MARK: HTTP entry point

    public func handle(_ request: HTTPRequest, _ ctx: ConnectionContext) async -> HTTPResponse {
        let started = Date()

        // Loopback-only, and never for a browser page: DNS-rebinding and CSRF defence.
        if let failure = validateOrigin(request) {
            log(.denied, pairing: nil, peer: nil, method: request.method, summary: failure)
            return .json(["error": .string(failure)], status: 403)
        }

        guard request.path == BridgeInfo.mcpPath || request.path == BridgeInfo.mcpPath + "/" else {
            return .json(["error": "not found", "hint": .string("MCP endpoint is \(BridgeInfo.mcpPath)")], status: 404)
        }

        // Authenticate every method, including GET and DELETE.
        let settings = settingsSource()
        let peer = peerResolver.flatMap { ctx.peerIdentity(resolver: $0) }
        let pairing: Pairing
        switch authenticate(request, peer: peer, settings: settings) {
        case .success(let p):
            pairing = p
        case .failure(let failure):
            log(.denied, pairing: nil, peer: peer?.displayName, method: request.method, summary: failure.message)
            var headers: [(String, String)] = []
            if failure.status == 401 {
                headers.append(("WWW-Authenticate", "Bearer realm=\"health-bridge\", error=\"invalid_token\""))
            }
            return .json(["error": .string(failure.message)], status: failure.status, headers: headers)
        }
        pairings.recordUse(id: pairing.id, peer: peer, bindIfUnbound: settings.bindPairingsToPeer)

        switch request.method {
        case "POST":
            return await handlePost(request, pairing: pairing, peer: peer, settings: settings, started: started)
        case "GET":
            // No server-initiated stream: nothing to push, so decline per spec.
            return .json(["error": "This server does not open server-to-client streams."], status: 405,
                         headers: [("Allow", "POST, DELETE")])
        case "DELETE":
            if let sid = request.header("mcp-session-id") {
                let removed = removeSession(sid)
                log(.ok, pairing: pairing, peer: peer?.displayName, method: "DELETE", summary: removed != nil ? "session ended" : "no such session")
                return .empty(removed != nil ? 200 : 404)
            }
            return .json(["error": "Mcp-Session-Id header required"], status: 400)
        default:
            return .json(["error": "method not allowed"], status: 405, headers: [("Allow", "POST, DELETE")])
        }
    }

    // MARK: Sessions

    private func lookupSession(_ id: String) -> MCPSession? {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return sessions[id]
    }

    private func removeSession(_ id: String) -> MCPSession? {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return sessions.removeValue(forKey: id)
    }

    private func storeSession(_ session: MCPSession) {
        sessionLock.lock(); defer { sessionLock.unlock() }
        sessions[session.id] = session
        if sessions.count > 256 {
            // Drop the oldest sessions; clients re-initialize on 404.
            for old in sessions.values.sorted(by: { $0.createdAt < $1.createdAt }).prefix(sessions.count - 256) {
                sessions.removeValue(forKey: old.id)
            }
        }
    }

    // MARK: Validation & auth

    func validateOrigin(_ request: HTTPRequest) -> String? {
        if let host = request.header("host") {
            let name = hostName(host)
            if !HTTPServer.isLoopback(name) { return "Host header must be a loopback address" }
        }
        if let origin = request.header("origin"), origin != "null" {
            guard let url = URL(string: origin), let h = url.host, HTTPServer.isLoopback(h) else {
                return "Cross-origin requests are not allowed"
            }
        }
        // Browsers always send Sec-Fetch-Mode; MCP clients never do. Refuse page-initiated traffic.
        if let mode = request.header("sec-fetch-mode"), mode != "same-origin", request.header("sec-fetch-site") == "cross-site" {
            return "Cross-site browser requests are not allowed"
        }
        return nil
    }

    private func hostName(_ host: String) -> String {
        var h = host
        if h.hasPrefix("[") {
            if let close = h.firstIndex(of: "]") { return String(h[h.index(after: h.startIndex)..<close]) }
        }
        if let colon = h.lastIndex(of: ":"), h.filter({ $0 == ":" }).count == 1 { h = String(h[..<colon]) }
        return h
    }

    func authenticate(_ request: HTTPRequest, peer: PeerIdentity?, settings: BridgeSettings) -> Result<Pairing, AuthFailure> {
        guard let auth = request.header("authorization") else { return .failure(.missingToken) }
        let parts = auth.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return .failure(.malformedToken) }
        let token = parts[1].trimmingCharacters(in: .whitespaces)

        let pairing: Pairing
        switch pairings.lookup(token: token) {
        case .success(let p): pairing = p
        case .failure(let f): return .failure(f)
        }

        if settings.bindPairingsToPeer, let bound = pairing.boundKey {
            guard let peer else {
                return .failure(.peerUnverifiable(boundTo: pairing.boundDisplayName ?? bound))
            }
            guard peer.bindingKey == bound else {
                return .failure(.peerMismatch(expected: pairing.boundDisplayName ?? bound, actual: peer.displayName))
            }
        }
        return .success(pairing)
    }

    // MARK: JSON-RPC

    private func handlePost(_ request: HTTPRequest, pairing: Pairing, peer: PeerIdentity?, settings: BridgeSettings,
                            started: Date) async -> HTTPResponse {
        if let ct = request.header("content-type"), !ct.lowercased().contains("application/json") {
            return .json(["error": "Content-Type must be application/json"], status: 415)
        }
        if let accept = request.header("accept"), !accept.contains("application/json"), !accept.contains("*/*") {
            return .json(["error": "Accept must include application/json"], status: 406)
        }

        let parsed: JSONValue
        do {
            parsed = try JSON.parse(request.body)
        } catch {
            log(.error, pairing: pairing, peer: peer?.displayName, method: "POST", summary: "parse error")
            let err = JSONRPCMessage.failure(id: nil, error: JSONRPCError(code: JSONRPCErrorCode.parseError, message: "Parse error"))
            return .json(err, status: 400)
        }

        let sessionHeader = request.header("mcp-session-id")
        if let sid = sessionHeader {
            let session = lookupSession(sid)
            if let session, session.pairingID != pairing.id {
                return .json(["error": "session belongs to another pairing"], status: 403)
            }
            if session == nil, !isInitialize(parsed) {
                // Unknown session: tell the client to start over.
                return .json(["error": "unknown session"], status: 404)
            }
        }

        var responseHeaders: [(String, String)] = []
        if let v = request.header("mcp-protocol-version"), BridgeInfo.supportedProtocolVersions.contains(v) {
            responseHeaders.append(("MCP-Protocol-Version", v))
        }

        let messages: [JSONValue]
        let isBatch: Bool
        if let arr = parsed.arrayValue {
            messages = arr
            isBatch = true
        } else {
            messages = [parsed]
            isBatch = false
        }
        if messages.isEmpty {
            let err = JSONRPCMessage.failure(id: nil, error: JSONRPCError(code: JSONRPCErrorCode.invalidRequest, message: "Empty batch"))
            return .json(err, status: 400)
        }

        var responses: [JSONValue] = []
        for raw in messages {
            guard let message = JSONRPCMessage(json: raw) else {
                // A response from the client (to a server request) or garbage; we send none, so ignore quietly.
                if raw["result"] != nil || raw["error"] != nil { continue }
                responses.append(JSONRPCMessage.failure(id: raw["id"], error: JSONRPCError(code: JSONRPCErrorCode.invalidRequest, message: "Invalid Request")))
                continue
            }
            if message.isNotification {
                handleNotification(message)
                continue
            }
            let (result, newSession) = await dispatch(message, pairing: pairing, peer: peer, settings: settings, started: started)
            if let newSession { responseHeaders.append(("Mcp-Session-Id", newSession)) }
            responses.append(result)
        }

        if responses.isEmpty { return .empty(202, headers: responseHeaders) }
        let body: JSONValue = isBatch ? .array(responses) : responses[0]
        return .json(body, headers: responseHeaders)
    }

    private func isInitialize(_ value: JSONValue) -> Bool {
        if let arr = value.arrayValue { return arr.contains { $0["method"]?.stringValue == "initialize" } }
        return value["method"]?.stringValue == "initialize"
    }

    private func handleNotification(_ message: JSONRPCMessage) {
        // initialized / cancelled / progress: nothing to do for a stateless read-only server.
    }

    private func dispatch(_ message: JSONRPCMessage, pairing: Pairing, peer: PeerIdentity?, settings: BridgeSettings,
                          started: Date) async -> (JSONValue, String?) {
        let id = message.id ?? .null
        switch message.method {
        case "initialize":
            let requested = message.params["protocolVersion"]?.stringValue ?? BridgeInfo.latestProtocolVersion
            let version = BridgeInfo.supportedProtocolVersions.contains(requested) ? requested : BridgeInfo.latestProtocolVersion
            let clientName = message.params["clientInfo"]?["name"]?.stringValue
            let session = MCPSession(id: UUID().uuidString, pairingID: pairing.id, protocolVersion: version,
                                     clientName: clientName, createdAt: Date())
            storeSession(session)
            log(.ok, pairing: pairing, peer: peer?.displayName, method: "initialize",
                summary: "client \(clientName ?? "unknown"), protocol \(version)", started: started)
            let result: JSONValue = [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(BridgeInfo.name), "title": .string(BridgeInfo.displayName), "version": .string(BridgeInfo.version)],
                "instructions": .string(Self.instructions),
            ]
            return (JSONRPCMessage.response(id: id, result: result), session.id)

        case "ping":
            return (JSONRPCMessage.response(id: id, result: .object([:])), nil)

        case "tools/list":
            log(.ok, pairing: pairing, peer: peer?.displayName, method: "tools/list", summary: "\(HealthTools.all.count) tools", started: started)
            return (JSONRPCMessage.response(id: id, result: ["tools": .array(HealthTools.all.map(\.listing))]), nil)

        case "tools/call":
            guard let name = message.params["name"]?.stringValue else {
                return (JSONRPCMessage.failure(id: id, error: JSONRPCError(code: JSONRPCErrorCode.invalidParams, message: "Missing tool name")), nil)
            }
            guard let tool = HealthTools.byName[name] else {
                log(.error, pairing: pairing, peer: peer?.displayName, method: "tools/call", tool: name, summary: "unknown tool", started: started)
                return (JSONRPCMessage.failure(id: id, error: JSONRPCError(code: JSONRPCErrorCode.invalidParams, message: "Unknown tool: \(name)")), nil)
            }
            let args = ToolArgs(message.params["arguments"] ?? .object([:]))
            do {
                let result = try await tool.handler(args, providerSource(), settings)
                log(.ok, pairing: pairing, peer: peer?.displayName, method: "tools/call", tool: name,
                    summary: Self.summarize(args: args.raw), started: started)
                let payload: JSONValue = [
                    "content": [["type": "text", "text": .string(JSON.string(result))]],
                    "structuredContent": result,
                    "isError": false,
                ]
                return (JSONRPCMessage.response(id: id, result: payload), nil)
            } catch {
                let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                log(.error, pairing: pairing, peer: peer?.displayName, method: "tools/call", tool: name, summary: text, started: started)
                let payload: JSONValue = [
                    "content": [["type": "text", "text": .string(text)]],
                    "isError": true,
                ]
                return (JSONRPCMessage.response(id: id, result: payload), nil)
            }

        case "resources/list":
            return (JSONRPCMessage.response(id: id, result: ["resources": []]), nil)
        case "resources/templates/list":
            return (JSONRPCMessage.response(id: id, result: ["resourceTemplates": []]), nil)
        case "prompts/list":
            return (JSONRPCMessage.response(id: id, result: ["prompts": []]), nil)
        case "logging/setLevel":
            return (JSONRPCMessage.response(id: id, result: .object([:])), nil)
        case "completion/complete":
            return (JSONRPCMessage.response(id: id, result: ["completion": ["values": []]]), nil)
        default:
            return (JSONRPCMessage.failure(id: id, error: JSONRPCError(code: JSONRPCErrorCode.methodNotFound, message: "Method not found: \(message.method)")), nil)
        }
    }

    static let instructions = """
    Flexpa Health Bridge exposes this person's Apple Health data, read-only, from their own Mac. \
    Start with health_status to learn the active data source and date coverage. \
    Prefer get_daily_summary and get_statistics for trends; use get_samples only when individual readings matter. \
    Times are in the user's local time zone. Treat everything returned as sensitive personal health information.
    """

    static func summarize(args: JSONValue) -> String {
        guard let obj = args.objectValue, !obj.isEmpty else { return "" }
        return obj.keys.sorted().compactMap { key in
            guard let v = obj[key] else { return nil }
            switch v {
            case .string(let s): return "\(key)=\(s)"
            case .number(let n): return "\(key)=\(n == n.rounded() ? String(Int(n)) : String(n))"
            case .bool(let b): return "\(key)=\(b)"
            case .array(let a): return "\(key)=[\(a.count)]"
            default: return key
            }
        }.joined(separator: " ")
    }

    private func log(_ outcome: AuditEvent.Outcome, pairing: Pairing?, peer: String?, method: String, tool: String? = nil,
                     summary: String, started: Date? = nil) {
        let ms = started.map { Int(Date().timeIntervalSince($0) * 1000) }
        audit.append(AuditEvent(outcome: outcome, pairingName: pairing?.name, pairingID: pairing?.id, peer: peer,
                                method: method, tool: tool, summary: summary, durationMs: ms))
    }
}
