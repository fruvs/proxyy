//
//  ProxyLibraryStore.swift
//  Proxyy
//
//  Created by Fruvs on 3/15/26.
//

import Foundation
import Security

enum ProxyLibraryStore {
    private static let legacyProxiesKey = "proxy.library.items"
    private static let lastConnectedProxyIDKey = "proxy.library.lastConnectedID"
    private static let credentialIDsKey = "proxy.library.credentialIDs"
    private static let directoryName = "Proxyy"
    private static let fileName = "proxies.json"

    static func loadProxies(defaults: UserDefaults = .standard) -> [ProxyEndpoint] {
        if let proxies = loadFromDisk() {
            return proxies.map(ProxyCredentialStore.enrich)
        }

        guard
            let data = defaults.data(forKey: legacyProxiesKey),
            let proxies = try? JSONDecoder().decode([ProxyEndpoint].self, from: data)
        else {
            return []
        }

        saveProxies(proxies, defaults: defaults)
        defaults.removeObject(forKey: legacyProxiesKey)
        return proxies
    }

    static func saveProxies(_ proxies: [ProxyEndpoint], defaults: UserDefaults = .standard) {
        syncCredentials(for: proxies, defaults: defaults)

        guard
            let data = try? JSONEncoder().encode(proxies),
            let url = try? storageURL()
        else {
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            defaults.removeObject(forKey: legacyProxiesKey)
        } catch {
            defaults.set(data, forKey: legacyProxiesKey)
        }
    }

    static func loadLastConnectedProxyID(defaults: UserDefaults = .standard) -> UUID? {
        guard let rawValue = defaults.string(forKey: lastConnectedProxyIDKey) else {
            return nil
        }

        return UUID(uuidString: rawValue)
    }

    static func saveLastConnectedProxyID(_ id: UUID?, defaults: UserDefaults = .standard) {
        defaults.set(id?.uuidString, forKey: lastConnectedProxyIDKey)
    }

    private static func loadFromDisk() -> [ProxyEndpoint]? {
        guard
            let url = try? storageURL(),
            let data = try? Data(contentsOf: url),
            let proxies = try? JSONDecoder().decode([ProxyEndpoint].self, from: data)
        else {
            return nil
        }

        return proxies
    }

    private static func syncCredentials(for proxies: [ProxyEndpoint], defaults: UserDefaults) {
        let currentIDs = Set(proxies.map { $0.id.uuidString })
        let previousIDs = Set(defaults.stringArray(forKey: credentialIDsKey) ?? [])

        for staleID in previousIDs.subtracting(currentIDs) {
            ProxyCredentialStore.delete(reference: staleID)
        }

        for proxy in proxies where proxy.hasCredentials {
            ProxyCredentialStore.save(
                credentials: ProxyCredentials(username: proxy.username, password: proxy.password),
                reference: proxy.id.uuidString
            )
        }

        defaults.set(Array(currentIDs).sorted(), forKey: credentialIDsKey)
    }

    private static func storageURL() throws -> URL {
        let baseURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        return baseURL
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }
}

private struct ProxyCredentials {
    let username: String?
    let password: String?

    init(username: String?, password: String?) {
        self.username = username
        self.password = password
    }

    nonisolated init?(data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }

        username = object["username"]
        password = object["password"]
    }

    nonisolated var encodedData: Data? {
        var object: [String: String] = [:]

        if let username {
            object["username"] = username
        }

        if let password {
            object["password"] = password
        }

        return try? JSONSerialization.data(withJSONObject: object)
    }
}

private enum ProxyCredentialStore {
    nonisolated private static let service = "fruvs.Proxyy.proxy.credentials"
    nonisolated private static let accessGroup = "985XZHBX3T.fruvs.Proxyy"

    nonisolated static func enrich(_ proxy: ProxyEndpoint) -> ProxyEndpoint {
        guard let credentials = load(reference: proxy.id.uuidString) else {
            return proxy
        }

        var copy = proxy
        copy.username = credentials.username
        copy.password = credentials.password
        return copy
    }

    nonisolated static func save(credentials: ProxyCredentials, reference: String) {
        guard let data = credentials.encodedData else {
            return
        }

        var query = baseQuery(reference: reference)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecItemNotFound else {
            return
        }

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    nonisolated static func delete(reference: String) {
        SecItemDelete(baseQuery(reference: reference) as CFDictionary)
    }

    nonisolated private static func load(reference: String) -> ProxyCredentials? {
        var query = baseQuery(reference: reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let credentials = ProxyCredentials(data: data) else {
            return nil
        }

        return credentials
    }

    nonisolated private static func baseQuery(reference: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
            kSecAttrAccessGroup as String: accessGroup
        ]
    }
}
