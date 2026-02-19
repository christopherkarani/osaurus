//
//  OpenClawKeychain.swift
//  osaurus
//

import Foundation
import Security

public enum OpenClawKeychain {
    nonisolated(unsafe) static var serviceOverride: String?

    private static let tokenAccount = "gateway.authToken"
    private static let deviceTokenAccount = "gateway.deviceToken"

    private static var service: String {
        serviceOverride ?? "ai.osaurus.openclaw"
    }

    @discardableResult
    public static func saveToken(_ token: String) -> Bool {
        save(value: token, account: tokenAccount)
    }

    public static func getToken() -> String? {
        get(account: tokenAccount)
    }

    @discardableResult
    public static func deleteToken() -> Bool {
        delete(account: tokenAccount)
    }

    public static func hasToken() -> Bool {
        getToken() != nil
    }

    @discardableResult
    public static func saveDeviceToken(_ token: String) -> Bool {
        save(value: token, account: deviceTokenAccount)
    }

    public static func getDeviceToken() -> String? {
        get(account: deviceTokenAccount)
    }

    @discardableResult
    public static func deleteDeviceToken() -> Bool {
        delete(account: deviceTokenAccount)
    }

    @discardableResult
    private static func save(value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        _ = delete(account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
            let data = result as? Data,
            let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return value
    }

    @discardableResult
    private static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
