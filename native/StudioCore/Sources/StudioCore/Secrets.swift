import Foundation
import CryptoKit
import CommonCrypto
import Security

/// 密钥存储。密钥永远不会写进项目目录或日志。
public protocol SecretStore: Sendable {
    func get(_ id: String) async -> String
    func has(_ id: String) async -> Bool
    func set(_ id: String, _ value: String) async throws
    func delete(_ id: String) async throws
    /// 所有已保存的密钥（用来从报错里抹掉密钥）。
    func values() async -> [String]
}

public enum SecretIds {
    public static func imageProvider(_ id: String) -> String { "image:\(id)" }
    public static func llmVendor(_ id: String) -> String { "llm:\(id)" }
}

/// 把错误信息里的密钥替换掉，再写日志或显示。
public func redact(_ text: String, _ secrets: [String] = []) -> String {
    var output = text
    for secret in secrets where secret.count >= 6 {
        output = output.replacingAll(secret, with: "<已隐藏>")
    }
    output = Rx.replace(#"Bearer\s+[A-Za-z0-9._\-]{8,}"#, in: output, with: "Bearer <已隐藏>")
    output = Rx.replace(#"(?<![A-Za-z0-9_])sk-[A-Za-z0-9_\-]{8,}"#, in: output, with: "sk-<已隐藏>")
    return output
}

/// 测试用：只放内存。
public actor MemorySecrets: SecretStore {
    private var store: [String: String]
    public init(_ initial: [String: String] = [:]) { store = initial }
    public func get(_ id: String) -> String { store[id] ?? "" }
    public func has(_ id: String) -> Bool { store[id] != nil }
    public func set(_ id: String, _ value: String) { if value.isEmpty { store[id] = nil } else { store[id] = value } }
    public func delete(_ id: String) { store[id] = nil }
    public func values() -> [String] { Array(store.values) }
}

/// 加密器：把明文密钥变成可以写进文件的字符串。
public protocol SecretCipher: Sendable {
    func encrypt(_ value: String) throws -> String
    func decrypt(_ value: String) throws -> String
}

/// secrets.json：每个密钥一条密文，密文由 cipher 生成（App 里用本机密钥文件里的 AES 密钥）。
public actor FileSecrets: SecretStore {
    private let file: String
    private let cipher: SecretCipher
    private var cache: [String: String]?

    public init(dataDir: String, cipher: SecretCipher) {
        file = Path.join(dataDir, "secrets.json")
        self.cipher = cipher
    }

    private func load() -> [String: String] {
        if let cache { return cache }
        var loaded: [String: String] = [:]
        if let object = FS.readJSONQuiet(file)?.object {
            for (key, value) in object { if let text = value.string { loaded[key] = text } }
        }
        cache = loaded
        return loaded
    }

    public func get(_ id: String) -> String {
        guard let entry = load()[id] else { return "" }
        return (try? cipher.decrypt(entry)) ?? ""
    }

    public func has(_ id: String) -> Bool { load()[id] != nil }

    public func set(_ id: String, _ value: String) throws {
        var store = load()
        if value.isEmpty { store[id] = nil } else { store[id] = try cipher.encrypt(value) }
        var object = JSONObject()
        for key in store.keys.sorted() { object[key] = .string(store[key]!) }
        try FS.writeJSONAtomic(file, .object(object), mode: 0o600)
        cache = store
    }

    public func delete(_ id: String) throws { try set(id, "") }

    public func values() -> [String] {
        load().values.compactMap { try? cipher.decrypt($0) }.filter { !$0.isEmpty }
    }
}

// MARK: - 钥匙串

public enum Keychain {
    public static func read(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    public static func write(service: String, account: String, data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = service
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw StudioError("无法写入钥匙串（\(added)）") }
        } else if status != errSecSuccess {
            throw StudioError("无法写入钥匙串（\(status)）")
        }
    }
}

/// App 用的加密器：AES-GCM，256 位密钥放在登录钥匙串里（每次启动只读一次钥匙串）。
public final class KeychainCipher: SecretCipher, @unchecked Sendable {
    public static let service = "软件指南生成器（原生版）"
    public static let account = "secrets-key"
    private let lock = NSLock()
    private var key: SymmetricKey?

    public init() {}

    private func symmetricKey() throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        if let key { return key }
        if let data = Keychain.read(service: Self.service, account: Self.account), data.count == 32 {
            key = SymmetricKey(data: data)
            return key!
        }
        let fresh = SymmetricKey(size: .bits256)
        let data = fresh.withUnsafeBytes { Data($0) }
        try Keychain.write(service: Self.service, account: Self.account, data: data)
        key = fresh
        return fresh
    }

    public func encrypt(_ value: String) throws -> String {
        guard let combined = try AES.GCM.seal(Data(value.utf8), using: symmetricKey()).combined else { throw StudioError("加密失败") }
        return combined.base64EncodedString()
    }

    public func decrypt(_ value: String) throws -> String {
        guard let data = Data(base64Encoded: value) else { throw StudioError("密文损坏") }
        let box = try AES.GCM.SealedBox(combined: data)
        return String(decoding: try AES.GCM.open(box, using: symmetricKey()), as: UTF8.self)
    }
}

/// 本机文件里的 AES-GCM 密钥（软件数据目录下的 secrets.key，权限 600）。
/// 不放钥匙串：临时签名的 App 每次升级签名都会变，钥匙串会把新版本当成别的 App，导致弹窗或读不到。
public final class LocalKeyCipher: SecretCipher, @unchecked Sendable {
    public let keyFile: String
    private let lock = NSLock()
    private var key: SymmetricKey?

    public init(dataDir: String) { keyFile = Path.join(dataDir, "secrets.key") }

    public var exists: Bool { FS.exists(keyFile) }

    private func symmetricKey() throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        if let key { return key }
        if let data = try? FS.read(keyFile), data.count == 32 {
            key = SymmetricKey(data: data)
            return key!
        }
        let fresh = SymmetricKey(size: .bits256)
        try FS.mkdirp(Path.dirname(keyFile))
        let created = FileManager.default.createFile(atPath: keyFile, contents: fresh.withUnsafeBytes { Data($0) }, attributes: [.posixPermissions: 0o600])
        guard created else { throw StudioError("无法保存本机密钥文件") }
        key = fresh
        return fresh
    }

    public func encrypt(_ value: String) throws -> String {
        guard let combined = try AES.GCM.seal(Data(value.utf8), using: symmetricKey()).combined else { throw StudioError("加密失败") }
        return combined.base64EncodedString()
    }

    public func decrypt(_ value: String) throws -> String {
        guard let data = Data(base64Encoded: value) else { throw StudioError("密文损坏") }
        let box = try AES.GCM.SealedBox(combined: data)
        return String(decoding: try AES.GCM.open(box, using: symmetricKey()), as: UTF8.self)
    }
}

/// App 用的密钥存储：secrets.json + 本机密钥文件。
/// 以前用钥匙串里的密钥加密过的，第一次打开时从钥匙串最后读一次，转成本机密钥加密；读不到的条目删掉（界面会显示「没有密钥」，重新填一次即可）。
public enum LocalSecrets {
    /// legacyKey：以前放在钥匙串里的 32 字节密钥（只在需要转换时读一次，只读不写）。
    public static func open(dataDir: String, legacyKey: () -> Data? = { Keychain.read(service: KeychainCipher.service, account: KeychainCipher.account) }) -> FileSecrets {
        let cipher = LocalKeyCipher(dataDir: dataDir)
        let file = Path.join(dataDir, "secrets.json")
        if !cipher.exists, let stored = FS.readJSONQuiet(file)?.object, !stored.isEmpty {
            let old = legacyKey().flatMap { $0.count == 32 ? SymmetricKey(data: $0) : nil }
            var converted = JSONObject()
            for (id, value) in stored {
                guard let old, let text = value.string, let data = Data(base64Encoded: text),
                      let box = try? AES.GCM.SealedBox(combined: data), let plain = try? AES.GCM.open(box, using: old),
                      let sealed = try? cipher.encrypt(String(decoding: plain, as: UTF8.self)) else { continue }
                converted[id] = .string(sealed)
            }
            if converted.isEmpty { _ = try? cipher.encrypt("") } // 至少把本机密钥建好，以后不再碰钥匙串
            try? FS.copy(file, file + ".keychain-backup")
            try? FS.writeJSONAtomic(file, .object(converted), mode: 0o600)
        }
        return FileSecrets(dataDir: dataDir, cipher: cipher)
    }
}

/// 读 Electron 版用 safeStorage 加密的密钥（迁移用）。
/// Chromium 在 macOS 上的做法：钥匙串里存一个口令，PBKDF2-SHA1(口令, "saltysalt", 1003 次) 得到 128 位密钥，
/// 密文 = "v10" + AES-128-CBC(IV 为 16 个空格)。
public struct ElectronSafeStorage: Sendable {
    public let password: Data

    public init(password: Data) { self.password = password }

    /// 从钥匙串读 Electron 版的口令（系统会弹窗询问是否允许）。
    public static func fromKeychain(appName: String = "软件指南生成器") -> ElectronSafeStorage? {
        guard let password = Keychain.read(service: "\(appName) Safe Storage", account: "\(appName) Key") else { return nil }
        return ElectronSafeStorage(password: password)
    }

    func derivedKey() -> Data {
        var key = Data(count: 16)
        let salt = Data("saltysalt".utf8)
        key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    _ = CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                        keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), 16)
                }
            }
        }
        return key
    }

    /// base64 的 safeStorage 密文 → 明文。
    public func decrypt(_ base64: String) throws -> String {
        guard let data = Data(base64Encoded: base64), data.count > 3, data.prefix(3) == Data("v10".utf8) else { throw StudioError("不是 safeStorage 密文") }
        let body = data.dropFirst(3)
        let key = derivedKey()
        let iv = Data(repeating: 0x20, count: 16)
        var output = Data(count: body.count + kCCBlockSizeAES128)
        var written = 0
        let outputCount = output.count
        let status = output.withUnsafeMutableBytes { outBytes in
            body.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, kCCKeySizeAES128, ivBytes.baseAddress,
                                inBytes.baseAddress, body.count, outBytes.baseAddress, outputCount, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw StudioError("解密失败（\(status)）") }
        return String(decoding: output.prefix(written), as: UTF8.self)
    }
}
