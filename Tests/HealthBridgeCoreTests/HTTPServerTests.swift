import XCTest
@testable import HealthBridgeCore

/// End to end over a real loopback socket.
final class HTTPServerTests: XCTestCase {
    func startServer(handler: @escaping HTTPServer.Handler) async throws -> HTTPServer {
        let server = HTTPServer(port: 0, handler: handler)
        let ready = expectation(description: "ready")
        try server.start { state in
            if case .ready = state { ready.fulfill() }
        }
        await fulfillment(of: [ready], timeout: 5)
        XCTAssertGreaterThan(server.port, 0)
        return server
    }

    func testRoundTripAndPeerIdentification() async throws {
        let seenPeer = Locked<PeerIdentity?>(nil)
        let server = try await startServer { request, ctx in
            seenPeer.value = ctx.peerIdentity(resolver: LibprocPeerResolver())
            return .json(["echo": .string(String(decoding: request.body, as: UTF8.self)), "path": .string(request.path)])
        }
        defer { server.stop() }

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/mcp")!)
        req.httpMethod = "POST"
        req.httpBody = Data("{\"hi\":1}".utf8)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let json = try JSON.parse(data)
        XCTAssertEqual(json["echo"]?.stringValue, "{\"hi\":1}")
        XCTAssertEqual(json["path"]?.stringValue, "/mcp")

        // The client lives in this very process, so libproc must find us.
        let peer = seenPeer.value
        XCTAssertNotNil(peer, "peer identity should resolve for a same-user loopback client")
        XCTAssertEqual(peer?.pid, ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(peer?.path?.split(separator: "/").last, "xctest")
        XCTAssertTrue(peer?.signatureValid ?? false)
    }

    func testFullMCPFlowOverTheWire() async throws {
        let pairings = PairingStore()
        let (_, token) = pairings.create(name: "wire")
        let provider = DemoHealthProvider(days: 5)
        let settings = BridgeSettings()
        let mcp = MCPServer(provider: { provider }, settings: { settings }, pairings: pairings, audit: AuditLog(url: nil))
        let server = try await startServer { request, ctx in await mcp.handle(request, ctx) }
        defer { server.stop() }

        func call(_ body: JSONValue, auth: Bool = true) async throws -> (Int, JSONValue, [AnyHashable: Any]) {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/mcp")!)
            req.httpMethod = "POST"
            req.httpBody = JSON.data(body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            if auth { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (data, response) = try await URLSession.shared.data(for: req)
            let http = response as! HTTPURLResponse
            return (http.statusCode, (try? JSON.parse(data)) ?? .null, http.allHeaderFields)
        }

        let (unauth, _, _) = try await call(["jsonrpc": "2.0", "id": 1, "method": "ping"], auth: false)
        XCTAssertEqual(unauth, 401)

        let (status, json, headers) = try await call(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18", "capabilities": .object([:]), "clientInfo": ["name": "xctest", "version": "1"]]])
        XCTAssertEqual(status, 200)
        XCTAssertEqual(json["result"]?["serverInfo"]?["name"]?.stringValue, "health-bridge")
        XCTAssertNotNil(headers["Mcp-Session-Id"] ?? headers["mcp-session-id"])

        let (s2, tools, _) = try await call(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        XCTAssertEqual(s2, 200)
        XCTAssertEqual(tools["result"]?["tools"]?.arrayValue?.count, HealthTools.all.count)

        let (s3, call3, _) = try await call(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "get_workouts", "arguments": ["start": "2000-01-01"]]])
        XCTAssertEqual(s3, 200)
        XCTAssertEqual(call3["result"]?["isError"]?.boolValue, false)
        XCTAssertGreaterThan(call3["result"]?["structuredContent"]?["count"]?.intValue ?? 0, 0)

        // The pairing is now bound to this test process (Apple-signed xctest).
        let bound = pairings.all[0]
        XCTAssertEqual(bound.requestCount, 3)
        XCTAssertNotNil(bound.lastUsedAt)
    }

    func testRefusesRequestsWithForeignHostHeader() async throws {
        let mcp = MCPServer(provider: { DemoHealthProvider(days: 1) }, settings: { BridgeSettings() }, pairings: PairingStore(), audit: AuditLog(url: nil))
        let server = try await startServer { request, ctx in await mcp.handle(request, ctx) }
        defer { server.stop() }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/mcp")!)
        req.httpMethod = "POST"
        req.httpBody = Data("{}".utf8)
        req.setValue("attacker.example", forHTTPHeaderField: "Host")
        let (_, response) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 403)
    }
}

final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
