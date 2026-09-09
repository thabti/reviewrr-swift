import Foundation
import Security

/// Why a Keychain read produced no secret.
///
/// Told apart deliberately. "There is no token saved" and "the reviewer
/// refused to hand this build the token" look identical if a read just
/// returns `nil`, so the app signed itself out silently and asked again on
/// the next launch — the loop these cases exist to break.
enum KeychainDenial: Equatable {
    /// The reviewer clicked Deny, or dismissed the panel.
    case userDeclined
    /// macOS could not ask — a locked keychain, or a non-interactive session.
    case interactionNotAllowed
    /// The keychain refused this build's identity.
    case authenticationFailed
}

enum KeychainReadResult: Equatable {
    case value(String)
    case notFound
    case denied(KeychainDenial)
    /// Anything else, carried as the raw status so a bug report can name it.
    /// Never carries secret material.
    case failed(OSStatus)
}

enum KeychainWriteResult: Equatable {
    case saved
    case denied(KeychainDenial)
    case failed(OSStatus)
}

/// Stores secrets (the GitHub token, AI provider keys) in the macOS
/// Keychain. Nothing here is written to UserDefaults, logs, or any file.
///
/// Secrets are keyed by *account* so several can coexist under one service:
/// `github-token`, `ai.anthropic`, `ai.openai`, and so on.
///
/// ## Why this app gets asked for permission so often
///
/// The legacy (file-based) keychain attaches an access-control list to each
/// item naming the application that created it — by code signature. This
/// project signs ad hoc (`CODE_SIGN_IDENTITY: "-"` in `project.yml`), so
/// *every rebuild produces a different signature*, macOS sees an unfamiliar
/// application asking for another application's secret, and it asks the
/// reviewer to approve it. Approving does not help the next build.
///
/// Two things follow, and both are implemented here:
///
/// 1. **The data-protection keychain is tried first.** It scopes items to the
///    application's identity rather than to an ACL, and never shows an
///    approval panel: an app either may read the item or may not. It needs a
///    real signing identity, so an ad-hoc build falls back to the legacy
///    keychain — `errSecMissingEntitlement` — which is detected once and
///    remembered for the process.
/// 2. **A refusal is a state, not a `nil`.** Callers get `denied` and can say
///    so, offer to use a token for this session only, and stop asking.
///
/// The durable fix for a development machine is a stable signing identity
/// (any Apple Development certificate): the ACL then matches across
/// rebuilds and macOS stops asking. Ad-hoc signing cannot be made stable.
enum KeychainStore {
    private static let service = "com.sabeur.reviewrr"

    enum Account {
        static let githubToken = "github-token"
        /// Per-provider AI credentials, e.g. `ai.anthropic`.
        static func aiProvider(_ id: String) -> String { "ai.\(id)" }
    }

    /// Whether the data-protection keychain is usable by this build. Resolved
    /// on the first call and reused: the answer depends on how the binary was
    /// signed, which cannot change while it is running.
    nonisolated(unsafe) private static var dataProtectionAvailable: Bool?

    // MARK: - Status mapping

    /// Pure, and the part worth testing: which statuses mean "the reviewer
    /// said no", which mean "nothing is stored", and which are real faults.
    static func denial(for status: OSStatus) -> KeychainDenial? {
        switch status {
        case errSecUserCanceled: return .userDeclined
        case errSecInteractionNotAllowed, errSecInteractionRequired: return .interactionNotAllowed
        case errSecAuthFailed: return .authenticationFailed
        default: return nil
        }
    }

    static func readResult(status: OSStatus, data: Data?) -> KeychainReadResult {
        if status == errSecSuccess {
            guard let data, let value = String(data: data, encoding: .utf8) else {
                return .failed(status)
            }
            return .value(value)
        }
        if status == errSecItemNotFound { return .notFound }
        if let denial = denial(for: status) { return .denied(denial) }
        return .failed(status)
    }

    // MARK: - Generic access

    @discardableResult
    static func save(_ value: String, account: String) -> Bool {
        if case .saved = write(value, account: account) { return true }
        return false
    }

    static func write(_ value: String, account: String) -> KeychainWriteResult {
        delete(account: account)
        guard let data = value.data(using: .utf8) else { return .failed(errSecParam) }

        var status = SecItemAdd(addQuery(account: account, data: data, dataProtection: true) as CFDictionary, nil)
        if status == errSecMissingEntitlement || status == errSecNotAvailable {
            dataProtectionAvailable = false
            status = SecItemAdd(addQuery(account: account, data: data, dataProtection: false) as CFDictionary, nil)
        } else if status == errSecSuccess {
            dataProtectionAvailable = true
        }

        if status == errSecSuccess { return .saved }
        if let denial = denial(for: status) { return .denied(denial) }
        return .failed(status)
    }

    static func load(account: String) -> String? {
        if case .value(let value) = read(account: account) { return value }
        return nil
    }

    static func read(account: String) -> KeychainReadResult {
        var item: CFTypeRef?
        var status = SecItemCopyMatching(
            readQuery(account: account, dataProtection: dataProtectionAvailable != false) as CFDictionary, &item
        )
        // An ad-hoc build has no entitlement for the data-protection
        // keychain; note that once and use the legacy one from here on.
        if status == errSecMissingEntitlement || status == errSecNotAvailable {
            dataProtectionAvailable = false
            item = nil
            status = SecItemCopyMatching(readQuery(account: account, dataProtection: false) as CFDictionary, &item)
        }
        // A token written before this build switched keychains lives in the
        // other one; look there rather than reporting it missing.
        if status == errSecItemNotFound, dataProtectionAvailable != false {
            item = nil
            status = SecItemCopyMatching(readQuery(account: account, dataProtection: false) as CFDictionary, &item)
        }
        return readResult(status: status, data: item as? Data)
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        var deleted = false
        for dataProtection in [true, false] {
            let status = SecItemDelete(baseQuery(account: account, dataProtection: dataProtection) as CFDictionary)
            deleted = deleted || status == errSecSuccess || status == errSecItemNotFound
        }
        return deleted
    }

    // MARK: - Queries

    private static func baseQuery(account: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    private static func addQuery(account: String, data: Data, dataProtection: Bool) -> [String: Any] {
        var query = baseQuery(account: account, dataProtection: dataProtection)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return query
    }

    private static func readQuery(account: String, dataProtection: Bool) -> [String: Any] {
        var query = baseQuery(account: account, dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }

    // MARK: - GitHub token convenience

    static func saveToken(_ token: String) { save(token, account: Account.githubToken) }
    static func loadToken() -> String? { load(account: Account.githubToken) }
    static func readToken() -> KeychainReadResult { read(account: Account.githubToken) }
    static func delete() { delete(account: Account.githubToken) }
}
