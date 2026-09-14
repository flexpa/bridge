import CryptoKit
import Foundation

/// A paired agent. The bridge only stores a hash of the bearer token; the
/// plaintext exists once, at creation, and then only inside the agent's config.
public struct Pairing: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var tokenHash: String
    /// First characters of the token so the user can match it to a config file.
    public var tokenPrefix: String
    public var createdAt: Date
    public var lastUsedAt: Date?
    public var revokedAt: Date?
    /// Code-signing identity this token is bound to after first use.
    public var boundKey: String?
    public var boundDisplayName: String?
    public var boundAt: Date?
    public var requestCount: Int

    public var isRevoked: Bool { revokedAt != nil }
    public var isBound: Bool { boundKey != nil }

    public init(id: UUID = UUID(), name: String, tokenHash: String, tokenPrefix: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.tokenHash = tokenHash
        self.tokenPrefix = tokenPrefix
        self.createdAt = createdAt
        self.requestCount = 0
    }
}

public enum PairingToken {
    public static let prefix = "hkb_"

    /// 256 bits of randomness, base64url without padding.
    public static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return prefix + base64url(Data(bytes))
    }

    public static func hash(_ token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func looksValid(_ token: String) -> Bool {
        token.hasPrefix(prefix) && token.count >= 40 && token.count <= 128
    }

    /// Constant-time comparison of two hex digests.
    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8), bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public enum AuthFailure: Error, Equatable, Sendable {
    case missingToken
    case malformedToken
    case unknownToken
    case revoked
    case peerMismatch(expected: String, actual: String?)
    case peerUnverifiable(boundTo: String)

    public var message: String {
        switch self {
        case .missingToken: return "Missing bearer token. Pair this agent in Flexpa Health Bridge and send Authorization: Bearer <token>."
        case .malformedToken: return "Malformed bearer token."
        case .unknownToken: return "Unknown bearer token. It may have been revoked or belong to another machine."
        case .revoked: return "This pairing was revoked in Flexpa Health Bridge."
        case .peerMismatch(let expected, let actual):
            return "This token is bound to \(expected) but the request came from \(actual ?? "an unidentified process"). Reset the binding in Flexpa Health Bridge to move the token."
        case .peerUnverifiable(let bound):
            return "This token is bound to \(bound) and the requesting process could not be identified. Requests must come from the same macOS user account."
        }
    }

    public var status: Int {
        switch self {
        case .missingToken, .malformedToken, .unknownToken, .revoked: return 401
        case .peerMismatch, .peerUnverifiable: return 403
        }
    }
}
