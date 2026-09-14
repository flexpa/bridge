import Foundation

public struct AuditEvent: Codable, Identifiable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case ok, denied, error
    }

    public var id: UUID
    public var at: Date
    public var outcome: Outcome
    public var pairingName: String?
    public var pairingID: UUID?
    public var peer: String?
    public var method: String
    public var tool: String?
    public var summary: String
    public var durationMs: Int?

    public init(id: UUID = UUID(), at: Date = Date(), outcome: Outcome, pairingName: String? = nil, pairingID: UUID? = nil,
                peer: String? = nil, method: String, tool: String? = nil, summary: String, durationMs: Int? = nil) {
        self.id = id
        self.at = at
        self.outcome = outcome
        self.pairingName = pairingName
        self.pairingID = pairingID
        self.peer = peer
        self.method = method
        self.tool = tool
        self.summary = summary
        self.durationMs = durationMs
    }
}

/// Append-only JSON Lines log of every request the bridge served or refused.
/// Keeps a bounded in-memory tail for the UI.
public final class AuditLog: @unchecked Sendable {
    private let url: URL?
    private let lock = NSLock()
    private var tail: [AuditEvent] = []
    private let tailLimit: Int
    private var handle: FileHandle?

    public var onAppend: (@Sendable (AuditEvent) -> Void)?

    public init(url: URL?, tailLimit: Int = 200) {
        self.url = url
        self.tailLimit = tailLimit
        if let url {
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
            loadTail()
        }
    }

    public var recent: [AuditEvent] {
        lock.lock(); defer { lock.unlock() }
        return tail
    }

    public func append(_ event: AuditEvent) {
        lock.lock()
        tail.append(event)
        if tail.count > tailLimit { tail.removeFirst(tail.count - tailLimit) }
        if let handle, let data = try? Self.encoder.encode(event) {
            var line = data
            line.append(0x0A)
            _ = try? handle.write(contentsOf: line)
        }
        lock.unlock()
        onAppend?(event)
    }

    public func clear() {
        lock.lock()
        tail.removeAll()
        if let url {
            try? handle?.close()
            try? Data().write(to: url)
            handle = try? FileHandle(forWritingTo: url)
        }
        lock.unlock()
    }

    private func loadTail() {
        guard let url, let data = try? Data(contentsOf: url) else { return }
        // Only decode the last chunk of a potentially large file.
        let slice = data.count > 256 * 1024 ? data.suffix(256 * 1024) : data[...]
        let text = String(decoding: slice, as: UTF8.self)
        var events: [AuditEvent] = []
        for line in text.split(separator: "\n").suffix(tailLimit) {
            if let e = try? Self.decoder.decode(AuditEvent.self, from: Data(line.utf8)) { events.append(e) }
        }
        tail = events
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
