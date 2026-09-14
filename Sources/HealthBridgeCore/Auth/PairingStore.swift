import Foundation

/// Persists pairings as JSON in Application Support with 0600 permissions.
public final class PairingStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var pairings: [Pairing]
    private var byHash: [String: Int] = [:]

    public var onChange: (@Sendable ([Pairing]) -> Void)?
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedDescriptor: Int32 = -1
    private var suppressReloadUntil = Date.distantPast

    public init(url: URL) {
        self.url = url
        pairings = Self.read(url) ?? []
        reindex()
        startWatching()
    }

    deinit {
        watcher?.cancel()
    }

    private static func read(_ url: URL) -> [Pairing]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode([Pairing].self, from: data)
    }

    /// Re-reads the file when another process (the CLI) changes it.
    private func startWatching() {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        watchedDescriptor = open(dir.path, O_EVTONLY)
        guard watchedDescriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: watchedDescriptor, eventMask: [.write, .rename],
                                                               queue: DispatchQueue.global(qos: .utility))
        source.setEventHandler { [weak self] in self?.reloadFromDisk() }
        source.setCancelHandler { [fd = watchedDescriptor] in close(fd) }
        source.resume()
        watcher = source
    }

    public func reloadFromDisk() {
        lock.lock()
        if Date() < suppressReloadUntil {
            lock.unlock()
            return
        }
        guard let fresh = Self.read(url), fresh != pairings else {
            lock.unlock()
            return
        }
        pairings = fresh
        reindex()
        lock.unlock()
        notify()
    }

    /// In-memory store for tests.
    public convenience init() {
        self.init(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("healthbridge-pairings-\(UUID().uuidString).json"))
    }

    public var all: [Pairing] {
        lock.lock(); defer { lock.unlock() }
        return pairings
    }

    public var active: [Pairing] { all.filter { !$0.isRevoked } }

    /// Creates a pairing and returns it with the one-time plaintext token.
    @discardableResult
    public func create(name: String) -> (pairing: Pairing, token: String) {
        let token = PairingToken.generate()
        let pairing = Pairing(name: name.isEmpty ? "Agent" : name, tokenHash: PairingToken.hash(token),
                              tokenPrefix: String(token.prefix(12)))
        lock.lock()
        pairings.append(pairing)
        reindex()
        persistLocked()
        lock.unlock()
        notify()
        return (pairing, token)
    }

    public func revoke(id: UUID) {
        mutate(id: id) { $0.revokedAt = Date() }
    }

    public func delete(id: UUID) {
        lock.lock()
        pairings.removeAll { $0.id == id }
        reindex()
        persistLocked()
        lock.unlock()
        notify()
    }

    public func rename(id: UUID, to name: String) {
        mutate(id: id) { $0.name = name }
    }

    public func resetBinding(id: UUID) {
        mutate(id: id) {
            $0.boundKey = nil
            $0.boundDisplayName = nil
            $0.boundAt = nil
        }
    }

    /// Looks up a pairing by bearer token without leaking timing on the hash.
    public func lookup(token: String) -> Result<Pairing, AuthFailure> {
        guard PairingToken.looksValid(token) else { return .failure(.malformedToken) }
        let hash = PairingToken.hash(token)
        lock.lock(); defer { lock.unlock() }
        // Scan every entry so timing does not depend on where the match is.
        var match: Pairing?
        for p in pairings where PairingToken.constantTimeEquals(p.tokenHash, hash) {
            match = p
        }
        guard let found = match else { return .failure(.unknownToken) }
        if found.isRevoked { return .failure(.revoked) }
        return .success(found)
    }

    /// Records a successful use; binds the pairing to `peer` on first use if requested.
    public func recordUse(id: UUID, peer: PeerIdentity?, bindIfUnbound: Bool) {
        mutate(id: id) { p in
            p.lastUsedAt = Date()
            p.requestCount += 1
            if bindIfUnbound, p.boundKey == nil, let peer, let key = peer.bindingKey {
                p.boundKey = key
                p.boundDisplayName = peer.displayName
                p.boundAt = Date()
            }
        }
    }

    private func mutate(id: UUID, _ body: (inout Pairing) -> Void) {
        lock.lock()
        if let i = pairings.firstIndex(where: { $0.id == id }) {
            body(&pairings[i])
            reindex()
            persistLocked()
        }
        lock.unlock()
        notify()
    }

    private func reindex() {
        byHash = [:]
        for (i, p) in pairings.enumerated() { byHash[p.tokenHash] = i }
    }

    private func persistLocked() {
        suppressReloadUntil = Date().addingTimeInterval(0.5)
        do {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try Self.encoder.encode(pairings)
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("HealthBridge: failed to persist pairings: \(error)")
        }
    }

    private func notify() {
        let snapshot = all
        onChange?(snapshot)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
