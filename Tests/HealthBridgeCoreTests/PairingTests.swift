import XCTest
@testable import HealthBridgeCore

final class PairingTests: XCTestCase {
    func testTokenShape() {
        let token = PairingToken.generate()
        XCTAssertTrue(token.hasPrefix("hkb_"))
        XCTAssertEqual(token.count, 4 + 43)
        XCTAssertTrue(PairingToken.looksValid(token))
        XCTAssertFalse(PairingToken.looksValid("nope"))
        XCTAssertNotEqual(PairingToken.generate(), token)
    }

    func testHashIsStableAndConstantTimeCompareWorks() {
        let h1 = PairingToken.hash("hkb_abc")
        XCTAssertEqual(h1, PairingToken.hash("hkb_abc"))
        XCTAssertEqual(h1.count, 64)
        XCTAssertTrue(PairingToken.constantTimeEquals(h1, h1))
        XCTAssertFalse(PairingToken.constantTimeEquals(h1, PairingToken.hash("hkb_abd")))
    }

    func testStoreLifecycle() {
        let store = PairingStore()
        let (pairing, token) = store.create(name: "Claude Code")
        XCTAssertEqual(store.active.count, 1)
        XCTAssertEqual(pairing.tokenPrefix, String(token.prefix(12)))

        switch store.lookup(token: token) {
        case .success(let p): XCTAssertEqual(p.id, pairing.id)
        case .failure(let f): XCTFail("unexpected \(f)")
        }
        XCTAssertEqual(store.lookup(token: "hkb_" + String(repeating: "x", count: 43)).failureValue, .unknownToken)
        XCTAssertEqual(store.lookup(token: "garbage").failureValue, .malformedToken)

        store.revoke(id: pairing.id)
        XCTAssertEqual(store.lookup(token: token).failureValue, .revoked)
        XCTAssertEqual(store.active.count, 0)
        XCTAssertEqual(store.all.count, 1)

        store.delete(id: pairing.id)
        XCTAssertEqual(store.all.count, 0)
    }

    func testBindingOnFirstUse() {
        let store = PairingStore()
        let (pairing, _) = store.create(name: "Agent")
        let peer = PeerIdentity(pid: 1, path: "/Applications/Claude.app/Contents/MacOS/Claude", name: "Claude", parentName: nil,
                                teamIdentifier: "ABCDE12345", signingIdentifier: "com.anthropic.claudefordesktop",
                                isApplePlatformBinary: false, isAdHocSigned: false, signatureValid: true)
        store.recordUse(id: pairing.id, peer: peer, bindIfUnbound: true)
        let bound = store.all[0]
        XCTAssertEqual(bound.boundKey, "team:ABCDE12345")
        XCTAssertEqual(bound.requestCount, 1)
        store.resetBinding(id: pairing.id)
        XCTAssertNil(store.all[0].boundKey)
    }

    func testAdHocPeerDoesNotBind() {
        let peer = PeerIdentity(pid: 1, path: "/opt/homebrew/bin/python3", name: "python3", parentName: nil, teamIdentifier: nil,
                                signingIdentifier: "python3", isApplePlatformBinary: false, isAdHocSigned: true, signatureValid: true)
        XCTAssertNil(peer.bindingKey)
        let apple = PeerIdentity(pid: 1, path: "/usr/bin/curl", name: "curl", parentName: nil, teamIdentifier: nil,
                                 signingIdentifier: "com.apple.curl", isApplePlatformBinary: true, isAdHocSigned: false, signatureValid: true)
        XCTAssertEqual(apple.bindingKey, "apple:com.apple.curl")
    }

    func testPersistenceRoundTrip() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hb-\(UUID().uuidString)/pairings.json")
        let store = PairingStore(url: url)
        let (_, token) = store.create(name: "Persisted")
        let reloaded = PairingStore(url: url)
        XCTAssertEqual(reloaded.all.count, 1)
        XCTAssertNotNil(reloaded.lookup(token: token).successValue)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs?[.posixPermissions] as? Int), 0o600)
    }
}

extension Result {
    var failureValue: Failure? { if case .failure(let f) = self { return f } else { return nil } }
    var successValue: Success? { if case .success(let s) = self { return s } else { return nil } }
}
