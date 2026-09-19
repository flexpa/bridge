import CommonCrypto
import Foundation

public enum BackupDecryptError: Error, LocalizedError, Sendable {
    case notEncrypted
    case malformedKeybag(String)
    case wrongPassword
    case missingClassKey(Int)
    case manifestUnreadable(String)
    case fileNotFound(String)
    case cryptoFailure(String)

    public var errorDescription: String? {
        switch self {
        case .notEncrypted: return "This backup is not encrypted, so it contains no Health data. Turn on \"Encrypt local backup\" in Finder and back up again."
        case .malformedKeybag(let s): return "Backup keybag could not be parsed: \(s)"
        case .wrongPassword: return "The backup password is incorrect."
        case .missingClassKey(let c): return "The backup keybag has no key for protection class \(c)."
        case .manifestUnreadable(let s): return "Manifest.db could not be read: \(s)"
        case .fileNotFound(let s): return "File not found in backup: \(s)"
        case .cryptoFailure(let s): return "Decryption failed: \(s)"
        }
    }
}

/// The `BackupKeyBag` blob from Manifest.plist: a TLV list of header attributes
/// followed by one block per protection class.
struct BackupKeybag {
    struct ClassKey {
        var uuid: Data
        var classID: Int
        var wrap: Int
        var keyType: Int
        var wrappedKey: Data?
        var key: Data?
    }

    var attributes: [String: Data] = [:]
    var classKeys: [Int: ClassKey] = [:]

    init(data: Data) throws {
        var offset = 0
        var current: ClassKey?
        func be32(_ d: Data) -> Int { d.reduce(0) { ($0 << 8) | Int($1) } }
        while offset + 8 <= data.count {
            let tag = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let length = be32(data[offset + 4..<offset + 8])
            offset += 8
            guard offset + length <= data.count else { throw BackupDecryptError.malformedKeybag("truncated at \(tag)") }
            let value = data[offset..<offset + length]
            offset += length
            switch tag {
            case "UUID":
                if let c = current { classKeys[c.classID] = c }
                if attributes["UUID"] == nil && current == nil {
                    attributes["UUID"] = Data(value)  // keybag UUID comes first
                } else {
                    current = ClassKey(uuid: Data(value), classID: 0, wrap: 0, keyType: 0)
                }
            case "CLAS": current?.classID = be32(value)
            case "WRAP": if current != nil { current?.wrap = be32(value) } else { attributes[tag] = Data(value) }
            case "KTYP": current?.keyType = be32(value)
            case "WPKY": current?.wrappedKey = Data(value)
            case "PBKY": break
            default: attributes[tag] = Data(value)
            }
        }
        if let c = current { classKeys[c.classID] = c }
        guard attributes["SALT"] != nil, attributes["ITER"] != nil else { throw BackupDecryptError.malformedKeybag("no SALT/ITER") }
    }

    func intAttribute(_ name: String) -> Int? {
        attributes[name].map { $0.reduce(0) { ($0 << 8) | Int($1) } }
    }

    /// Derives the passcode key and unwraps every passcode-wrapped class key.
    mutating func unlock(password: String, progress: ((String) -> Void)? = nil) throws {
        guard let salt = attributes["SALT"], let iterations = intAttribute("ITER") else { throw BackupDecryptError.malformedKeybag("no SALT/ITER") }
        var intermediate = Data(password.utf8)
        if let dpsl = attributes["DPSL"], let dpic = intAttribute("DPIC") {
            // iOS 10.2+: a slow SHA-256 round first, then the classic SHA-1 round.
            progress?("Deriving key (\(dpic.formatted()) rounds)")
            intermediate = try Crypto.pbkdf2(password: intermediate, salt: dpsl, rounds: dpic, algorithm: kCCPRFHmacAlgSHA256, length: 32)
        }
        let passcodeKey = try Crypto.pbkdf2(password: intermediate, salt: salt, rounds: iterations, algorithm: kCCPRFHmacAlgSHA1, length: 32)
        var unlockedAny = false
        for (id, var ck) in classKeys {
            guard let wrapped = ck.wrappedKey, ck.wrap & 2 != 0, ck.keyType == 0 else { continue }
            guard let key = Crypto.aesUnwrap(kek: passcodeKey, wrapped: wrapped) else { throw BackupDecryptError.wrongPassword }
            ck.key = key
            classKeys[id] = ck
            unlockedAny = true
        }
        if !unlockedAny { throw BackupDecryptError.wrongPassword }
    }

    /// Unwraps a per-file (or manifest) key: 4 bytes little-endian class, then the wrapped key.
    func unwrapFileKey(_ blob: Data) throws -> Data {
        guard blob.count > 4 else { throw BackupDecryptError.cryptoFailure("file key too short") }
        let classID = blob.prefix(4).reversed().reduce(0) { ($0 << 8) | Int($1) }
        guard let classKey = classKeys[classID]?.key else { throw BackupDecryptError.missingClassKey(classID) }
        guard let key = Crypto.aesUnwrap(kek: classKey, wrapped: Data(blob.dropFirst(4))) else {
            throw BackupDecryptError.cryptoFailure("file key unwrap failed for class \(classID)")
        }
        return key
    }
}

/// Decrypts the parts of an encrypted iPhone backup we need: Manifest.db and
/// named files. Keys live only in memory for the life of this object.
public final class BackupDecryptor {
    public let backup: DeviceBackup
    private var keybag: BackupKeybag
    private let manifestKeyBlob: Data
    public var progress: ((String) -> Void)?

    public init(backup: DeviceBackup) throws {
        self.backup = backup
        let manifest = try BackupLocator.readPlist(backup.directory.appendingPathComponent("Manifest.plist"))
        guard manifest["IsEncrypted"] as? Bool == true else { throw BackupDecryptError.notEncrypted }
        guard let keybagData = manifest["BackupKeyBag"] as? Data, let manifestKey = manifest["ManifestKey"] as? Data else {
            throw BackupDecryptError.malformedKeybag("Manifest.plist lacks BackupKeyBag or ManifestKey")
        }
        keybag = try BackupKeybag(data: keybagData)
        manifestKeyBlob = manifestKey
    }

    public func unlock(password: String) throws {
        try keybag.unlock(password: password, progress: progress)
    }

    /// Decrypts Manifest.db to `destination`.
    public func decryptManifest(to destination: URL) throws {
        let key = try keybag.unwrapFileKey(manifestKeyBlob)
        let source = backup.directory.appendingPathComponent("Manifest.db")
        try Crypto.aesCBCDecryptFile(source: source, destination: destination, key: key, plaintextSize: nil)
    }

    public struct FileRecord: Sendable {
        public var fileID: String
        public var domain: String
        public var relativePath: String
        public var size: Int?
        public var encryptionKey: Data?
        public var storedURL: URL
    }

    /// Looks up files by domain and path prefix in a decrypted Manifest.db.
    public func files(inManifest manifestDB: URL, domain: String, pathPrefix: String) throws -> [FileRecord] {
        let db = try SQLiteDatabase(path: manifestDB.path)
        let rows = try db.query("SELECT fileID, domain, relativePath, file FROM Files WHERE domain = ? AND relativePath LIKE ? AND flags = 1",
                                bind: { $0.bind(1, domain); $0.bind(2, pathPrefix + "%") },
                                row: { ($0.string(0) ?? "", $0.string(1) ?? "", $0.string(2) ?? "", $0.blob(3)) })
        return rows.map { fileID, domain, path, blob in
            let (size, key) = Self.parseFileRecord(blob)
            let stored = backup.directory.appendingPathComponent(String(fileID.prefix(2))).appendingPathComponent(fileID)
            return FileRecord(fileID: fileID, domain: domain, relativePath: path, size: size, encryptionKey: key, storedURL: stored)
        }
    }

    /// The `file` column is an NSKeyedArchiver plist of Apple's private MBFile class.
    /// A stand-in class decodes just the two keys we need.
    static func parseFileRecord(_ blob: Data?) -> (Int?, Data?) {
        guard let blob, let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: blob) else { return (nil, nil) }
        // Secure coding stays on and the class list stays closed. This blob comes from a
        // Manifest.db the imported backup controls, and an unrestricted decode would let it
        // name arbitrary classes and run their initWithCoder:.
        unarchiver.requiresSecureCoding = true
        unarchiver.setClass(MBFileStub.self, forClassName: "MBFile")
        let allowed: [AnyClass] = [MBFileStub.self, NSData.self, NSNumber.self, NSString.self, NSDate.self]
        guard let file = unarchiver.decodeObject(of: allowed, forKey: "root") as? MBFileStub else { return (nil, nil) }
        return (file.size, file.encryptionKey)
    }

    /// Decrypts one file record to `destination`.
    public func decrypt(_ record: FileRecord, to destination: URL) throws {
        guard FileManager.default.fileExists(atPath: record.storedURL.path) else { throw BackupDecryptError.fileNotFound(record.relativePath) }
        guard let keyBlob = record.encryptionKey else { throw BackupDecryptError.cryptoFailure("no encryption key for \(record.relativePath)") }
        let key = try keybag.unwrapFileKey(keyBlob)
        try Crypto.aesCBCDecryptFile(source: record.storedURL, destination: destination, key: key, plaintextSize: record.size)
    }
}

/// Decodes the fields of Apple's MBFile archive that describe an encrypted file.
@objc(HealthBridgeMBFileStub)
final class MBFileStub: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    var size: Int?
    var encryptionKey: Data?
    var protectionClass: Int?

    override init() { super.init() }

    init(size: Int, encryptionKey: Data, protectionClass: Int) {
        self.size = size
        self.encryptionKey = encryptionKey
        self.protectionClass = protectionClass
    }

    required init?(coder: NSCoder) {
        super.init()
        if coder.containsValue(forKey: "Size") { size = Int(coder.decodeInt64(forKey: "Size")) }
        if coder.containsValue(forKey: "ProtectionClass") { protectionClass = Int(coder.decodeInt64(forKey: "ProtectionClass")) }
        encryptionKey = coder.decodeObject(of: NSData.self, forKey: "EncryptionKey") as Data?
    }

    func encode(with coder: NSCoder) {
        if let size { coder.encode(Int64(size), forKey: "Size") }
        if let protectionClass { coder.encode(Int64(protectionClass), forKey: "ProtectionClass") }
        if let encryptionKey { coder.encode(encryptionKey as NSData, forKey: "EncryptionKey") }
    }
}

/// Thin CommonCrypto wrappers. Zero third-party dependencies.
enum Crypto {
    static func pbkdf2(password: Data, salt: Data, rounds: Int, algorithm: Int, length: Int) throws -> Data {
        var derived = Data(count: length)
        let status = derived.withUnsafeMutableBytes { out in
            password.withUnsafeBytes { pw in
                salt.withUnsafeBytes { s in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         pw.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                                         s.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                         CCPseudoRandomAlgorithm(algorithm), UInt32(rounds),
                                         out.baseAddress?.assumingMemoryBound(to: UInt8.self), length)
                }
            }
        }
        guard status == kCCSuccess else { throw BackupDecryptError.cryptoFailure("PBKDF2 failed (\(status))") }
        return derived
    }

    /// RFC 3394 AES key unwrap. Returns nil when the integrity check fails (wrong KEK).
    static func aesUnwrap(kek: Data, wrapped: Data) -> Data? {
        var rawLength = CCSymmetricUnwrappedSize(CCWrappingAlgorithm(kCCWRAPAES), wrapped.count)
        var raw = Data(count: rawLength)
        let status = raw.withUnsafeMutableBytes { out in
            kek.withUnsafeBytes { k in
                wrapped.withUnsafeBytes { w in
                    CCSymmetricKeyUnwrap(CCWrappingAlgorithm(kCCWRAPAES), CCrfc3394_iv, CCrfc3394_ivLen,
                                         k.baseAddress?.assumingMemoryBound(to: UInt8.self), kek.count,
                                         w.baseAddress?.assumingMemoryBound(to: UInt8.self), wrapped.count,
                                         out.baseAddress?.assumingMemoryBound(to: UInt8.self), &rawLength)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return raw.prefix(rawLength)
    }

    /// RFC 3394 AES key wrap (used by tests to build synthetic backups).
    static func aesWrap(kek: Data, raw: Data) -> Data? {
        var wrappedLength = CCSymmetricWrappedSize(CCWrappingAlgorithm(kCCWRAPAES), raw.count)
        var wrapped = Data(count: wrappedLength)
        let status = wrapped.withUnsafeMutableBytes { out in
            kek.withUnsafeBytes { k in
                raw.withUnsafeBytes { r in
                    CCSymmetricKeyWrap(CCWrappingAlgorithm(kCCWRAPAES), CCrfc3394_iv, CCrfc3394_ivLen,
                                       k.baseAddress?.assumingMemoryBound(to: UInt8.self), kek.count,
                                       r.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count,
                                       out.baseAddress?.assumingMemoryBound(to: UInt8.self), &wrappedLength)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return wrapped.prefix(wrappedLength)
    }

    /// AES-256-CBC with a zero IV and PKCS#7 padding, streamed so gigabyte databases never sit in memory.
    static func aesCBCDecryptFile(source: URL, destination: URL, key: Data, plaintextSize: Int?) throws {
        try aesCBCFile(source: source, destination: destination, key: key, operation: CCOperation(kCCDecrypt), truncateTo: plaintextSize)
    }

    static func aesCBCEncryptFile(source: URL, destination: URL, key: Data) throws {
        try aesCBCFile(source: source, destination: destination, key: key, operation: CCOperation(kCCEncrypt), truncateTo: nil)
    }

    private static func aesCBCFile(source: URL, destination: URL, key: Data, operation: CCOperation, truncateTo: Int?) throws {
        var cryptor: CCCryptorRef?
        let iv = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        let created = key.withUnsafeBytes { k in
            CCCryptorCreate(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            k.baseAddress, key.count, iv, &cryptor)
        }
        guard created == kCCSuccess, let cryptor else { throw BackupDecryptError.cryptoFailure("cryptor create failed (\(created))") }
        defer { CCCryptorRelease(cryptor) }

        guard let input = FileHandle(forReadingAtPath: source.path) else { throw BackupDecryptError.fileNotFound(source.lastPathComponent) }
        defer { try? input.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
        guard let output = FileHandle(forWritingAtPath: destination.path) else { throw BackupDecryptError.cryptoFailure("cannot write \(destination.lastPathComponent)") }
        defer { try? output.close() }

        let chunk = 4 * 1024 * 1024
        var outBuffer = [UInt8](repeating: 0, count: chunk + kCCBlockSizeAES128)
        while true {
            let data = input.readData(ofLength: chunk)
            if data.isEmpty { break }
            var moved = 0
            let status = data.withUnsafeBytes { inPtr in
                CCCryptorUpdate(cryptor, inPtr.baseAddress, data.count, &outBuffer, outBuffer.count, &moved)
            }
            guard status == kCCSuccess else { throw BackupDecryptError.cryptoFailure("update failed (\(status))") }
            if moved > 0 { output.write(Data(outBuffer[0..<moved])) }
        }
        var moved = 0
        let final = CCCryptorFinal(cryptor, &outBuffer, outBuffer.count, &moved)
        guard final == kCCSuccess else { throw BackupDecryptError.cryptoFailure(final == kCCDecodeError ? "bad padding (wrong key?)" : "final failed (\(final))") }
        if moved > 0 { output.write(Data(outBuffer[0..<moved])) }
        if let size = truncateTo { try output.truncate(atOffset: UInt64(size)) }
    }
}
