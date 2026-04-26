//
//  ProxyEndpoint.swift
//  Proxyy
//
//  Created by Fruvs on 3/15/26.
//

import Foundation
import CFNetwork
enum ProxyScheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case unknown
    case http
    case https
    case socks
    case socks4
    case socks5

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unknown:
            return "AUTO"
        case .http:
            return "HTTP"
        case .https:
            return "HTTPS"
        case .socks:
            return "SOCKS"
        case .socks4:
            return "SOCKS4"
        case .socks5:
            return "SOCKS5"
        }
    }

    var isSOCKS: Bool {
        switch self {
        case .socks, .socks4, .socks5:
            return true
        default:
            return false
        }
    }

    var isResolved: Bool {
        self != .unknown
    }
}

enum ProxySchemeOrigin: String, Codable, Sendable {
    case explicit
    case detected
    case unknown

    var priority: Int {
        switch self {
        case .explicit:
            return 3
        case .detected:
            return 2
        case .unknown:
            return 1
        }
    }
}

struct ProxyEndpoint: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var label: String
    var scheme: ProxyScheme
    var schemeOrigin: ProxySchemeOrigin
    var host: String
    var port: Int
    var username: String?
    var password: String?
    var benchmark: ProxyBenchmark?

    init(
        id: UUID = UUID(),
        label: String = "",
        scheme: ProxyScheme,
        schemeOrigin: ProxySchemeOrigin = .explicit,
        host: String,
        port: Int,
        username: String? = nil,
        password: String? = nil,
        benchmark: ProxyBenchmark? = nil
    ) {
        self.id = id
        self.label = label
        self.scheme = scheme
        self.schemeOrigin = schemeOrigin
        self.host = host
        self.port = port
        self.username = Self.clean(username)
        self.password = Self.clean(password)
        self.benchmark = benchmark
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        scheme = try container.decodeIfPresent(ProxyScheme.self, forKey: .scheme) ?? .unknown
        schemeOrigin = try container.decodeIfPresent(ProxySchemeOrigin.self, forKey: .schemeOrigin) ?? .explicit
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        username = Self.clean(try container.decodeIfPresent(String.self, forKey: .username))
        password = Self.clean(try container.decodeIfPresent(String.self, forKey: .password))
        benchmark = try container.decodeIfPresent(ProxyBenchmark.self, forKey: .benchmark)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(scheme, forKey: .scheme)
        try container.encode(schemeOrigin, forKey: .schemeOrigin)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encodeIfPresent(benchmark, forKey: .benchmark)
    }

    var displayName: String {
        label.isEmpty ? host : label
    }

    var addressText: String {
        "\(host):\(port)"
    }

    var hasCredentials: Bool {
        username != nil || password != nil
    }

    nonisolated var needsDetection: Bool {
        schemeOrigin == .unknown || scheme == .unknown
    }

    var typeBadge: String {
        scheme.title
    }

    var subtitle: String {
        addressText
    }

    var benchmarkStatusText: String? {
        benchmark?.statusText
    }

    var benchmarkLocationText: String? {
        benchmark?.location?.displayName
    }

    var connectionScore: Double {
        benchmark?.rankingScore ?? -1
    }

    var endpointKey: String {
        [
            host.lowercased(),
            String(port),
            username ?? "",
            password ?? ""
        ]
        .joined(separator: "|")
    }

    var profilePayload: [String: Any] {
        let payload: [String: Any] = [
            ProxyTunnelConfiguration.Keys.label: label,
            ProxyTunnelConfiguration.Keys.scheme: scheme.rawValue,
            ProxyTunnelConfiguration.Keys.host: host,
            ProxyTunnelConfiguration.Keys.port: port,
            ProxyTunnelConfiguration.Keys.credentialReference: id.uuidString
        ]

        return payload
    }

    func applyingDetectedScheme(_ detectedScheme: ProxyScheme) -> ProxyEndpoint {
        var copy = self
        copy.scheme = detectedScheme
        copy.schemeOrigin = detectedScheme == .unknown ? .unknown : .detected
        return copy
    }

    func applyingBenchmark(_ benchmark: ProxyBenchmark) -> ProxyEndpoint {
        var copy = self
        copy.benchmark = benchmark
        return copy
    }

    func mergingMetadata(with other: ProxyEndpoint) -> ProxyEndpoint {
        var copy = self

        if copy.label.isEmpty, !other.label.isEmpty {
            copy.label = other.label
        }

        if copy.username == nil, let username = other.username {
            copy.username = username
        }

        if copy.password == nil, let password = other.password {
            copy.password = password
        }

        if other.schemeOrigin.priority > copy.schemeOrigin.priority
            || (other.schemeOrigin.priority == copy.schemeOrigin.priority
                && !copy.scheme.isResolved
                && other.scheme.isResolved) {
            copy.scheme = other.scheme
            copy.schemeOrigin = other.schemeOrigin
        }

        if let otherBenchmark = other.benchmark {
            if let currentBenchmark = copy.benchmark {
                if otherBenchmark.testedAt >= currentBenchmark.testedAt {
                    copy.benchmark = otherBenchmark
                }
            } else {
                copy.benchmark = otherBenchmark
            }
        }

        return copy
    }

    nonisolated var sessionProxyConfiguration: [AnyHashable: Any] {
        switch scheme {
        case .http, .https:
            return [
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: host,
                kCFNetworkProxiesHTTPPort as String: port
            ]

        case .socks, .socks4, .socks5:
            var dictionary: [AnyHashable: Any] = [
                "SOCKSEnable": 1,
                "SOCKSProxy": host,
                "SOCKSPort": port
            ]

            if let username {
                dictionary["SOCKSUser"] = username
            }

            if let password {
                dictionary["SOCKSPassword"] = password
            }

            return dictionary

        case .unknown:
            return [:]
        }
    }

    private static func clean(_ value: String?) -> String? {
        guard let cleanedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines), !cleanedValue.isEmpty else {
            return nil
        }

        return cleanedValue
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case scheme
        case schemeOrigin
        case host
        case port
        case username
        case password
        case benchmark
    }
}

struct ProxyBenchmark: Codable, Hashable, Sendable {
    nonisolated static let currentSchemaVersion = 2

    var schemaVersion: Int?
    var testedAt: Date
    var latencyMilliseconds: Double?
    var downloadMegabitsPerSecond: Double?
    var exitIPAddress: String?
    var location: ProxyLocation?
    var isReachable: Bool
    var failureReason: String?

    var isCurrent: Bool {
        schemaVersion == Self.currentSchemaVersion
    }

    var rankingScore: Double {
        guard isReachable else { return -1 }

        let speedScore = downloadMegabitsPerSecond ?? 0
        let latencyPenalty = (latencyMilliseconds ?? 600) / 100
        return speedScore - latencyPenalty
    }

    var statusText: String {
        guard isReachable else {
            return "Offline"
        }

        var parts: [String] = []

        if let latencyMilliseconds {
            parts.append("\(Int(latencyMilliseconds.rounded())) ms")
        }

        if let downloadMegabitsPerSecond {
            parts.append(String(format: "%.1f Mbps", downloadMegabitsPerSecond))
        }

        if parts.isEmpty {
            return "Ready"
        }

        return parts.joined(separator: " • ")
    }
}

struct ProxyLocation: Codable, Hashable, Sendable {
    var city: String?
    var region: String?
    var country: String
    var countryCode: String?

    var displayName: String {
        var parts: [String] = []

        if let city, !city.isEmpty {
            parts.append(city)
        }

        if let region, !region.isEmpty, region.caseInsensitiveCompare(city ?? "") != .orderedSame {
            parts.append(region)
        }

        if country.isEmpty == false {
            parts.append(country)
        }

        if parts.isEmpty {
            return country
        }

        return parts.joined(separator: ", ")
    }

    var groupKey: String {
        var parts: [String] = []

        if let countryCode, !countryCode.isEmpty {
            parts.append(countryCode.lowercased())
        }

        if let region, !region.isEmpty {
            parts.append(region.lowercased())
        }

        if let city, !city.isEmpty {
            parts.append(city.lowercased())
        }

        return parts.isEmpty ? country.lowercased() : parts.joined(separator: "|")
    }
}

enum ProxyTunnelConfiguration {
    enum Keys {
        static let label = "label"
        static let scheme = "scheme"
        static let host = "host"
        static let port = "port"
        static let credentialReference = "credentialReference"
        static let username = "username"
        static let password = "password"
    }
}
