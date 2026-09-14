import XCTest
@testable import HealthBridgeCore

/// A resolver that returns whatever identity the test sets.
final class StubResolver: PeerIdentityResolver, @unchecked Sendable {
    var identity: PeerIdentity?
    init(_ identity: PeerIdentity?) { self.identity = identity }
    func resolve(peerPort: UInt16, serverPort: UInt16) -> PeerIdentity? { identity }
}

final class MCPServerTests: XCTestCase {
    var pairings: PairingStore!
    var audit: AuditLog!
    var settings = BridgeSettings()
    var resolver: StubResolver!
    var server: MCPServer!
    var token = ""

    override func setUp() {
        pairings = PairingStore()
        audit = AuditLog(url: nil)
        settings = BridgeSettings()
        resolver = StubResolver(nil)
        let provider = DemoHealthProvider(days: 10)
        let settingsRef = settings
        server = MCPServer(provider: { provider }, settings: { settingsRef }, pairings: pairings, audit: audit, peerResolver: resolver)
        token = pairings.create(name: "Test Agent").token
    }

    func ctx() -> ConnectionContext {
        ConnectionContext(id: UUID(), peerHost: "127.0.0.1", peerPort: 50000, serverPort: 4271)
    }

    func post(_ body: JSONValue, token: String? = nil, headers: [String: String] = [:], connection: ConnectionContext? = nil) async -> HTTPResponse {
        var h: [String: String] = ["Host": "127.0.0.1:4271", "Content-Type": "application/json", "Accept": "application/json, text/event-stream"]
        if let token { h["Authorization"] = "Bearer \(token)" }
        for (k, v) in headers { h[k] = v }
        let request = HTTPRequest(method: "POST", path: "/mcp", headers: h, body: JSON.data(body))
        return await server.handle(request, connection ?? ctx())
    }

    func rpc(_ method: String, _ params: JSONValue = .object([:]), id: Int = 1) -> JSONValue {
        ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]
    }

    func body(_ r: HTTPResponse) -> JSONValue { (try? JSON.parse(r.body)) ?? .null }

    // MARK: Auth & origin

    func testMissingTokenIs401WithChallenge() async {
        let r = await post(rpc("tools/list"))
        XCTAssertEqual(r.status, 401)
        XCTAssertTrue(r.headers.contains { $0.0 == "WWW-Authenticate" })
        XCTAssertEqual(audit.recent.last?.outcome, .denied)
    }

    func testUnknownTokenIs401() async {
        let r = await post(rpc("tools/list"), token: "hkb_" + String(repeating: "a", count: 43))
        XCTAssertEqual(r.status, 401)
    }

    func testRevokedTokenIs401() async {
        pairings.revoke(id: pairings.all[0].id)
        let r = await post(rpc("tools/list"), token: token)
        XCTAssertEqual(r.status, 401)
        XCTAssertTrue(body(r)["error"]?.stringValue?.contains("revoked") ?? false)
    }

    func testNonLoopbackHostIsRejected() async {
        let r = await post(rpc("tools/list"), token: token, headers: ["Host": "evil.example.com"])
        XCTAssertEqual(r.status, 403)
    }

    func testCrossOriginIsRejected() async {
        let r = await post(rpc("tools/list"), token: token, headers: ["Origin": "https://evil.example.com"])
        XCTAssertEqual(r.status, 403)
        let ok = await post(rpc("tools/list"), token: token, headers: ["Origin": "http://localhost:3000"])
        XCTAssertEqual(ok.status, 200)
    }

    func testWrongPathIs404() async {
        let request = HTTPRequest(method: "POST", path: "/", headers: ["Host": "127.0.0.1", "Authorization": "Bearer \(token)"], body: JSON.data(rpc("ping")))
        let r = await server.handle(request, ctx())
        XCTAssertEqual(r.status, 404)
    }

    func testGetIs405AndDeleteEndsSession() async {
        let get = await server.handle(HTTPRequest(method: "GET", path: "/mcp", headers: ["Host": "127.0.0.1", "Authorization": "Bearer \(token)"]), ctx())
        XCTAssertEqual(get.status, 405)

        let initR = await post(rpc("initialize", ["protocolVersion": "2025-06-18", "clientInfo": ["name": "test"]]), token: token)
        let sid = initR.headers.first { $0.0 == "Mcp-Session-Id" }?.1
        XCTAssertNotNil(sid)
        let del = await server.handle(HTTPRequest(method: "DELETE", path: "/mcp", headers: ["Host": "127.0.0.1", "Authorization": "Bearer \(token)", "Mcp-Session-Id": sid!]), ctx())
        XCTAssertEqual(del.status, 200)
        let again = await post(rpc("ping"), token: token, headers: ["Mcp-Session-Id": sid!])
        XCTAssertEqual(again.status, 404)
    }

    // MARK: Peer binding

    func testTokenBindsToFirstPeerAndRejectsOthers() async {
        resolver.identity = PeerIdentity(pid: 10, path: "/Applications/Claude.app/Contents/MacOS/Claude", name: "Claude", parentName: nil,
                                         teamIdentifier: "TEAM1", signingIdentifier: "com.anthropic.claude", isApplePlatformBinary: false,
                                         isAdHocSigned: false, signatureValid: true)
        let first = await post(rpc("ping"), token: token)
        XCTAssertEqual(first.status, 200)
        XCTAssertEqual(pairings.all[0].boundKey, "team:TEAM1")

        resolver.identity = PeerIdentity(pid: 11, path: "/tmp/evil", name: "evil", parentName: nil, teamIdentifier: "TEAM2",
                                         signingIdentifier: "evil", isApplePlatformBinary: false, isAdHocSigned: false, signatureValid: true)
        let second = await post(rpc("ping"), token: token)
        XCTAssertEqual(second.status, 403)
        XCTAssertTrue(body(second)["error"]?.stringValue?.contains("bound to") ?? false)

        // Unidentifiable peer (e.g. another macOS user) is refused once bound.
        resolver.identity = nil
        let third = await post(rpc("ping"), token: token)
        XCTAssertEqual(third.status, 403)

        pairings.resetBinding(id: pairings.all[0].id)
        let fourth = await post(rpc("ping"), token: token)
        XCTAssertEqual(fourth.status, 200)
        XCTAssertEqual(pairings.all[0].boundKey, nil)  // nil resolver → nothing to bind to
    }

    func testBindingDisabledInSettingsAllowsAnyPeer() async {
        var mutable = BridgeSettings()
        mutable.bindPairingsToPeer = false
        let s = mutable
        let provider = DemoHealthProvider(days: 3)
        server = MCPServer(provider: { provider }, settings: { s }, pairings: pairings, audit: audit, peerResolver: resolver)
        resolver.identity = PeerIdentity(pid: 10, path: nil, name: "a", parentName: nil, teamIdentifier: "T1", signingIdentifier: "a",
                                         isApplePlatformBinary: false, isAdHocSigned: false, signatureValid: true)
        _ = await post(rpc("ping"), token: token)
        resolver.identity = PeerIdentity(pid: 11, path: nil, name: "b", parentName: nil, teamIdentifier: "T2", signingIdentifier: "b",
                                         isApplePlatformBinary: false, isAdHocSigned: false, signatureValid: true)
        let r = await post(rpc("ping"), token: token)
        XCTAssertEqual(r.status, 200)
        XCTAssertNil(pairings.all[0].boundKey)
    }

    // MARK: JSON-RPC

    func testInitializeNegotiatesProtocolVersion() async {
        let r = await post(rpc("initialize", ["protocolVersion": "2025-03-26", "capabilities": .object([:]), "clientInfo": ["name": "claude-code", "version": "1.0"]]), token: token)
        XCTAssertEqual(r.status, 200)
        let result = body(r)["result"]
        XCTAssertEqual(result?["protocolVersion"]?.stringValue, "2025-03-26")
        XCTAssertEqual(result?["serverInfo"]?["name"]?.stringValue, "health-bridge")
        XCTAssertNotNil(result?["capabilities"]?["tools"])
        XCTAssertTrue(r.headers.contains { $0.0 == "Mcp-Session-Id" })

        let unknown = await post(rpc("initialize", ["protocolVersion": "1999-01-01"]), token: token)
        XCTAssertEqual(body(unknown)["result"]?["protocolVersion"]?.stringValue, BridgeInfo.latestProtocolVersion)
    }

    func testNotificationReturns202() async {
        let r = await post(["jsonrpc": "2.0", "method": "notifications/initialized"], token: token)
        XCTAssertEqual(r.status, 202)
        XCTAssertTrue(r.body.isEmpty)
    }

    func testParseErrorIs400() async {
        let request = HTTPRequest(method: "POST", path: "/mcp", headers: ["Host": "127.0.0.1", "Authorization": "Bearer \(token)", "Content-Type": "application/json"], body: Data("{not json".utf8))
        let r = await server.handle(request, ctx())
        XCTAssertEqual(r.status, 400)
        XCTAssertEqual(body(r)["error"]?["code"]?.intValue, -32700)
    }

    func testUnknownMethod() async {
        let r = await post(rpc("nope/nothing"), token: token)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(body(r)["error"]?["code"]?.intValue, -32601)
    }

    func testBatch() async {
        let r = await post([rpc("ping", id: 1), rpc("tools/list", id: 2)], token: token)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(body(r).arrayValue?.count, 2)
    }

    func testToolsListDescribesEveryTool() async {
        let r = await post(rpc("tools/list"), token: token)
        let tools = body(r)["result"]?["tools"]?.arrayValue ?? []
        XCTAssertEqual(tools.count, HealthTools.all.count)
        let names = Set(tools.compactMap { $0["name"]?.stringValue })
        XCTAssertTrue(names.isSuperset(of: ["health_status", "get_samples", "get_statistics", "get_daily_summary", "get_sleep", "get_workouts", "get_clinical_records"]))
        for t in tools {
            XCTAssertEqual(t["inputSchema"]?["type"]?.stringValue, "object")
            XCTAssertEqual(t["annotations"]?["readOnlyHint"]?.boolValue, true)
        }
    }

    func testUnknownToolIsInvalidParams() async {
        let r = await post(rpc("tools/call", ["name": "delete_everything", "arguments": .object([:])]), token: token)
        XCTAssertEqual(body(r)["error"]?["code"]?.intValue, -32602)
    }

    func testToolErrorsAreReportedInResult() async {
        let r = await post(rpc("tools/call", ["name": "get_samples", "arguments": ["type": "bogus"]]), token: token)
        let result = body(r)["result"]
        XCTAssertEqual(result?["isError"]?.boolValue, true)
        XCTAssertTrue(result?["content"]?[0]?["text"]?.stringValue?.contains("Unsupported type") ?? false)
    }

    func testStatisticsAndDailySummaryOnDemoData() async {
        let stats = await post(rpc("tools/call", ["name": "get_statistics", "arguments": ["type": "stepCount", "start": "-7d-placeholder"]]), token: token)
        XCTAssertEqual(body(stats)["result"]?["isError"]?.boolValue, true)  // bad date → tool error, not crash

        let ok = await post(rpc("tools/call", ["name": "get_statistics", "arguments": ["type": "stepCount", "interval": "day"]]), token: token)
        let result = body(ok)["result"]
        XCTAssertEqual(result?["isError"]?.boolValue, false)
        let structured = result?["structuredContent"]
        XCTAssertEqual(structured?["aggregation"]?.stringValue, "cumulative")
        XCTAssertGreaterThan(structured?["buckets"]?.arrayValue?.count ?? 0, 5)
        XCTAssertGreaterThan(structured?["total"]?.doubleValue ?? 0, 0)

        let summary = await post(rpc("tools/call", ["name": "get_daily_summary", "arguments": ["start": "yesterday", "end": "today"]]), token: token)
        let days = body(summary)["result"]?["structuredContent"]?["days"]?.arrayValue ?? []
        XCTAssertEqual(days.count, 1)
        XCTAssertGreaterThan(days[0]["steps"]?.doubleValue ?? 0, 0)
        XCTAssertNotNil(days[0]["sleepAsleepMinutes"]?.doubleValue)
        XCTAssertNotNil(days[0]["restingHeartRate"]?.doubleValue)
    }

    func testSleepLatestAndClinicalTools() async {
        let tooWide = await post(rpc("tools/call", ["name": "get_sleep", "arguments": ["start": "2000-01-01"]]), token: token)
        XCTAssertEqual(body(tooWide)["result"]?["isError"]?.boolValue, true)  // > 366 days is refused

        let sleep = await post(rpc("tools/call", ["name": "get_sleep", "arguments": ["include_segments": true]]), token: token)
        XCTAssertEqual(body(sleep)["result"]?["isError"]?.boolValue, false)
        let nights = body(sleep)["result"]?["structuredContent"]?["nights"]?.arrayValue ?? []
        XCTAssertGreaterThan(nights.count, 5)
        XCTAssertNotNil(nights.first?["segments"])

        let latest = await post(rpc("tools/call", ["name": "get_latest", "arguments": ["types": ["bodyMass", "restingHeartRate", "bogus"]]]), token: token)
        let l = body(latest)["result"]?["structuredContent"]?["latest"]
        XCTAssertNotNil(l?["HKQuantityTypeIdentifierBodyMass"]?["value"]?.doubleValue)
        XCTAssertEqual(l?["bogus"]?["error"]?.stringValue, "unsupported type")

        let clinical = await post(rpc("tools/call", ["name": "get_clinical_records", "arguments": ["kind": "labResultRecord"]]), token: token)
        let records = body(clinical)["result"]?["structuredContent"]?["records"]?.arrayValue ?? []
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["resource"]?["resourceType"]?.stringValue, "Observation")

        let status = await post(rpc("tools/call", ["name": "health_status", "arguments": .object([:])]), token: token)
        XCTAssertEqual(body(status)["result"]?["structuredContent"]?["kind"]?.stringValue, "demo")
    }

    func testClinicalRecordsCanBeDisabled() async {
        var mutable = BridgeSettings()
        mutable.exposeClinicalRecords = false
        let s = mutable
        let provider = DemoHealthProvider(days: 3)
        server = MCPServer(provider: { provider }, settings: { s }, pairings: pairings, audit: audit, peerResolver: resolver)
        let r = await post(rpc("tools/call", ["name": "get_clinical_records", "arguments": .object([:])]), token: token)
        XCTAssertEqual(body(r)["result"]?["isError"]?.boolValue, true)
    }

    func testAuditRecordsToolCalls() async {
        _ = await post(rpc("tools/call", ["name": "get_workouts", "arguments": ["limit": 3]]), token: token)
        let event = audit.recent.last
        XCTAssertEqual(event?.tool, "get_workouts")
        XCTAssertEqual(event?.pairingName, "Test Agent")
        XCTAssertEqual(event?.summary, "limit=3")
    }
}
