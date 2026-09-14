import CLibProc
import Foundation
import Security

/// What we could learn about the process on the other end of a loopback socket.
public struct PeerIdentity: Codable, Equatable, Sendable {
    public var pid: Int32
    public var path: String?
    public var name: String
    public var parentName: String?
    public var teamIdentifier: String?
    public var signingIdentifier: String?
    public var isApplePlatformBinary: Bool
    public var isAdHocSigned: Bool
    public var signatureValid: Bool

    /// A stable key a pairing can be bound to. Team ID for third-party
    /// software, `apple:<identifier>` for Apple platform binaries, nil when
    /// the peer is unsigned or ad-hoc signed (nothing trustworthy to bind to).
    public var bindingKey: String? {
        guard signatureValid, !isAdHocSigned else { return nil }
        if let team = teamIdentifier, !team.isEmpty { return "team:\(team)" }
        if isApplePlatformBinary, let id = signingIdentifier { return "apple:\(id)" }
        return nil
    }

    public var displayName: String {
        if let team = teamIdentifier, !team.isEmpty, signatureValid {
            return "\(name) (Team \(team))"
        }
        if isApplePlatformBinary { return "\(name) (Apple)" }
        if isAdHocSigned { return "\(name) (ad-hoc signed)" }
        return signatureValid ? name : "\(name) (unsigned)"
    }
}

public protocol PeerIdentityResolver: Sendable {
    func resolve(peerPort: UInt16, serverPort: UInt16) -> PeerIdentity?
}

/// Maps the peer's ephemeral port to a pid with libproc, then asks the code
/// signing subsystem who signed that process.
public struct LibprocPeerResolver: PeerIdentityResolver {
    public init() {}

    public func resolve(peerPort: UInt16, serverPort: UInt16) -> PeerIdentity? {
        var pid: pid_t = 0
        guard clp_find_pid_for_tcp_peer(peerPort, serverPort, &pid) == 0, pid > 0 else { return nil }
        return Self.identity(forPid: pid)
    }

    public static func identity(forPid pid: pid_t) -> PeerIdentity {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = clp_pid_path(pid, &buf, UInt32(buf.count))
        let path: String? = n > 0 ? String(cString: buf) : nil
        let name = displayName(forPath: path) ?? "pid \(pid)"

        var parentName: String? = nil
        let ppid = clp_parent_pid(pid)
        if ppid > 1 {
            var pbuf = [CChar](repeating: 0, count: 4096)
            if clp_pid_path(ppid, &pbuf, UInt32(pbuf.count)) > 0 {
                parentName = displayName(forPath: String(cString: pbuf))
            }
        }

        var identity = PeerIdentity(pid: pid, path: path, name: name, parentName: parentName, teamIdentifier: nil,
                                    signingIdentifier: nil, isApplePlatformBinary: false, isAdHocSigned: false,
                                    signatureValid: false)

        var codeRef: SecCode?
        let attrs: [CFString: Any] = [kSecGuestAttributePid: pid]
        guard SecCodeCopyGuestWithAttributes(nil, attrs as CFDictionary, [], &codeRef) == errSecSuccess,
              let code = codeRef else { return identity }

        identity.signatureValid = SecCodeCheckValidity(code, [], nil) == errSecSuccess

        var staticRef: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticRef) == errSecSuccess, let staticCode = staticRef else {
            return identity
        }

        var infoRef: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        if SecCodeCopySigningInformation(staticCode, flags, &infoRef) == errSecSuccess,
           let info = infoRef as? [String: Any] {
            identity.teamIdentifier = info[kSecCodeInfoTeamIdentifier as String] as? String
            identity.signingIdentifier = info[kSecCodeInfoIdentifier as String] as? String
            if let f = info[kSecCodeInfoFlags as String] as? UInt32 {
                identity.isAdHocSigned = (f & 0x2) != 0  // kSecCodeSignatureAdhoc
            }
        }

        var reqRef: SecRequirement?
        if SecRequirementCreateWithString("anchor apple" as CFString, [], &reqRef) == errSecSuccess, let req = reqRef {
            identity.isApplePlatformBinary = SecStaticCodeCheckValidity(staticCode, [], req) == errSecSuccess
        }
        return identity
    }

    /// `/Applications/Claude.app/Contents/MacOS/Claude` → `Claude`; `/usr/bin/curl` → `curl`.
    static func displayName(forPath path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let components = path.split(separator: "/").map(String.init)
        if let app = components.first(where: { $0.hasSuffix(".app") }) {
            return String(app.dropLast(4))
        }
        return components.last
    }
}
