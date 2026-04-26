//
//  ProxyListParser.swift
//  Proxyy
//
//  Created by Fruvs on 3/15/26.
//

import Foundation

struct ProxyImportIssue: Identifiable, Hashable, Sendable {
    let id = UUID()
    let lineNumber: Int
    let rawValue: String
    let reason: String
}

struct ProxyImportResult: Sendable {
    let proxies: [ProxyEndpoint]
    let issues: [ProxyImportIssue]
}

private struct ProxyParseFailure: Error {
    let reason: String
}

enum ProxyListParser {
    static func parse(_ rawText: String) -> ProxyImportResult {
        let lines = rawText
            .components(separatedBy: .newlines)
            .enumerated()

        var importedByKey: [String: ProxyEndpoint] = [:]
        var orderedKeys: [String] = []
        var issues: [ProxyImportIssue] = []

        for (index, originalLine) in lines {
            let line = originalLine.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !line.isEmpty, !line.hasPrefix("#") else {
                continue
            }

            switch parseLine(line) {
            case .success(let proxy):
                if let existing = importedByKey[proxy.endpointKey] {
                    importedByKey[proxy.endpointKey] = existing.mergingMetadata(with: proxy)
                } else {
                    importedByKey[proxy.endpointKey] = proxy
                    orderedKeys.append(proxy.endpointKey)
                }
            case .failure(let failure):
                issues.append(
                    ProxyImportIssue(
                        lineNumber: index + 1,
                        rawValue: originalLine,
                        reason: failure.reason
                    )
                )
            }
        }

        return ProxyImportResult(
            proxies: orderedKeys.compactMap { importedByKey[$0] },
            issues: issues
        )
    }

    private static func parseLine(_ line: String) -> Result<ProxyEndpoint, ProxyParseFailure> {
        if line.contains("://") {
            return parseProxyURL(line)
        }

        return parseRawProxy(line)
    }

    private static func parseProxyURL(_ line: String) -> Result<ProxyEndpoint, ProxyParseFailure> {
        guard let components = URLComponents(string: line) else {
            return .failure(ProxyParseFailure(reason: "The proxy URL could not be read."))
        }

        guard let schemeValue = components.scheme?.lowercased(),
              let scheme = ProxyScheme(rawValue: schemeValue) else {
            return .failure(ProxyParseFailure(reason: "Use http://, https://, socks://, socks4://, or socks5:// when providing a scheme."))
        }

        guard let host = components.host, !host.isEmpty else {
            return .failure(ProxyParseFailure(reason: "Each proxy must include a host."))
        }

        guard let port = components.port, (1...65535).contains(port) else {
            return .failure(ProxyParseFailure(reason: "Each proxy must include a valid port."))
        }

        return .success(
            ProxyEndpoint(
                scheme: scheme,
                schemeOrigin: .explicit,
                host: host,
                port: port,
                username: components.user?.removingPercentEncoding,
                password: components.password?.removingPercentEncoding
            )
        )
    }

    private static func parseRawProxy(_ line: String) -> Result<ProxyEndpoint, ProxyParseFailure> {
        let parts = line.split(separator: ":", omittingEmptySubsequences: false)

        guard parts.count == 2 || parts.count == 4 else {
            return .failure(ProxyParseFailure(reason: "Use ip:port or ip:port:user:pass for raw proxy lines."))
        }

        let host = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        let portString = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        let username = parts.count == 4 ? String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let password = parts.count == 4 ? String(parts[3]).trimmingCharacters(in: .whitespacesAndNewlines) : nil

        guard !host.isEmpty else {
            return .failure(ProxyParseFailure(reason: "Each proxy must include a host."))
        }

        guard let port = Int(portString), (1...65535).contains(port) else {
            return .failure(ProxyParseFailure(reason: "Each proxy must include a valid port."))
        }

        return .success(
            ProxyEndpoint(
                scheme: .unknown,
                schemeOrigin: .unknown,
                host: host,
                port: port,
                username: username,
                password: password
            )
        )
    }
}
