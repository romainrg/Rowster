import Foundation
import Security

public struct SecretStoreError: Error, Equatable, Sendable {
    public let status: Int32
    public var message: String { SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)" }
}

/// The only place passwords are kept. Nothing else in Rowster persists a secret.
public protocol SecretStore: Sendable {
    func password(for connection: UUID) throws -> String?
    func setPassword(_ password: String, for connection: UUID) throws
    func deletePassword(for connection: UUID) throws
}

/// Generic passwords in the user's login Keychain, one per connection.
public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String = "io.github.romainrg.Rowster") { self.service = service }

    private func query(_ connection: UUID) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: connection.uuidString]
    }

    public func password(for connection: UUID) throws -> String? {
        var query = query(connection)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw SecretStoreError(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func setPassword(_ password: String, for connection: UUID) throws {
        let data = Data(password.utf8)
        var status = SecItemUpdate(query(connection) as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(connection)
            item[kSecValueData] = data
            item[kSecAttrLabel] = "Rowster"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SecretStoreError(status: status) }
    }

    public func deletePassword(for connection: UUID) throws {
        let status = SecItemDelete(query(connection) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError(status: status) }
    }
}

/// Keeps passwords in memory only: demo mode and tests.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var passwords: [UUID: String] = [:]

    public init() {}

    public func password(for connection: UUID) throws -> String? { lock.withLock { passwords[connection] } }
    public func setPassword(_ password: String, for connection: UUID) throws { lock.withLock { passwords[connection] = password } }
    public func deletePassword(for connection: UUID) throws { lock.withLock { passwords[connection] = nil } }
}
