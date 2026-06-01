#if canImport(Security)
    import Foundation
    import Security

    /// An ``AccountStore`` backed by the macOS / iOS Keychain (Apple platforms only).
    ///
    /// Each account is a generic-password item whose data (the private key) is guarded by a
    /// biometric / device-passcode access control (`.userPresence`), so retrieving a key for a
    /// payment prompts for Touch ID. Listing names reads attributes only (no prompt); the default
    /// account name is a separate, non-secret item. Mirrors the consumer app's keychain pattern
    /// (`SecAccessControlCreateWithFlags(.userPresence)` + `kSecUseDataProtectionKeychain`).
    ///
    /// - Note: like a CLI Touch ID prompt, key retrieval from a bare (non-bundled) `mpp` binary is
    ///   best-effort; the robust path is a bundled GUI consumer. Headless / CI use
    ///   `MPP_PRIVATE_KEY` instead.
    public struct KeychainAccountStore: AccountStore {
        private let keyService = "com.mpp.account-key"
        private let configService = "com.mpp.account-config"
        private let defaultAccountKey = "default-account"

        public init() {}

        public func store(_ privateKey: Data, name: String, label: String) throws {
            try delete(name: name)
            var accessError: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &accessError
            ) else {
                accessError?.release()
                throw AccountStoreError.ioFailure("could not create access control")
            }
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keyService,
                kSecAttrAccount as String: name,
                // The label (the display address) is a non-secret attribute, so accounts() can read
                // it without prompting; only the key data is behind the access control.
                kSecAttrLabel as String: label,
                kSecValueData as String: privateKey,
                kSecAttrAccessControl as String: access,
                kSecUseDataProtectionKeychain as String: true,
            ]
            let status = SecItemAdd(query as CFDictionary, nil)
            guard status == errSecSuccess
            else { throw AccountStoreError.ioFailure("add \(status)") }
        }

        public func privateKey(name: String) throws -> Data {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keyService,
                kSecAttrAccount as String: name,
                kSecReturnData as String: true,
                kSecUseDataProtectionKeychain as String: true,
            ]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            guard status == errSecSuccess, let data = item as? Data else {
                throw status == errSecItemNotFound
                    ? AccountStoreError.notFound(name)
                    : AccountStoreError.ioFailure("copy \(status)")
            }
            return data
        }

        public func accounts() throws -> [Account] {
            // Attributes only (no key data), so a userPresence item is listed without a prompt.
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keyService,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecReturnAttributes as String: true,
                kSecUseDataProtectionKeychain as String: true,
            ]
            var items: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &items)
            if status == errSecItemNotFound { return [] }
            guard status == errSecSuccess, let array = items as? [[String: Any]] else {
                throw AccountStoreError.ioFailure("list \(status)")
            }
            return array.compactMap { attributes in
                (attributes[kSecAttrAccount as String] as? String).map { name in
                    Account(name: name, label: attributes[kSecAttrLabel as String] as? String ?? "")
                }
            }.sorted { $0.name < $1.name }
        }

        public func delete(name: String) throws {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keyService,
                kSecAttrAccount as String: name,
                kSecUseDataProtectionKeychain as String: true,
            ]
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw AccountStoreError.ioFailure("delete \(status)")
            }
        }

        public func defaultName() throws -> String? {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: configService,
                kSecAttrAccount as String: defaultAccountKey,
                kSecReturnData as String: true,
                kSecUseDataProtectionKeychain as String: true,
            ]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = item as? Data else {
                throw AccountStoreError.ioFailure("default \(status)")
            }
            return String(data: data, encoding: .utf8)
        }

        public func setDefaultName(_ name: String?) throws {
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: configService,
                kSecAttrAccount as String: defaultAccountKey,
                kSecUseDataProtectionKeychain as String: true,
            ]
            SecItemDelete(base as CFDictionary)
            guard let name else { return }
            var add = base
            add[kSecValueData as String] = Data(name.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw AccountStoreError.ioFailure("set default \(status)")
            }
        }
    }
#endif
