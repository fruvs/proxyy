//
//  ProxyyTests.swift
//  ProxyyTests
//
//  Created by Fruvs on 3/15/26.
//

import Foundation
import Testing
@testable import Proxyy

@MainActor
struct ProxyyTests {

    @Test
    func importsRawAndURLProxyFormats() async throws {
        let result = ProxyListParser.parse(
            """
            203.0.113.10:8080:user:pass
            198.51.100.9:1080
            http://alpha:beta@proxy.example.com:8080
            socks5://gamma:delta@198.51.100.8:3128
            """
        )

        #expect(result.proxies.count == 4)
        #expect(result.issues.isEmpty)
        #expect(result.proxies[0].scheme == .unknown)
        #expect(result.proxies[0].schemeOrigin == .unknown)
        #expect(result.proxies[0].username == "user")
        #expect(result.proxies[0].password == "pass")
        #expect(result.proxies[2].scheme == .http)
        #expect(result.proxies[2].username == "alpha")
        #expect(result.proxies[3].scheme == .socks5)
    }

    @Test
    func rejectsUnsupportedProxyLines() async throws {
        let result = ProxyListParser.parse(
            """
            ftp://203.0.113.10:1080
            203.0.113.11:user:pass
            badline
            """
        )

        #expect(result.proxies.isEmpty)
        #expect(result.issues.count == 3)
    }

    @Test
    func deduplicatesImportedEndpoints() async throws {
        let result = ProxyListParser.parse(
            """
            203.0.113.10:8080
            http://203.0.113.10:8080
            203.0.113.10:8080:admin:secret
            """
        )

        #expect(result.proxies.count == 2)
        #expect(result.issues.isEmpty)
        #expect(result.proxies[0].scheme == .http)
        #expect(result.proxies[1].username == "admin")
    }

    @Test
    func encodedProxyOmitsCredentialsFromStoredJSONAndTunnelPayload() async throws {
        let proxy = ProxyEndpoint(
            scheme: .http,
            host: "proxy.example.com",
            port: 8080,
            username: "admin",
            password: "secret"
        )

        let data = try JSONEncoder().encode(proxy)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["username"] == nil)
        #expect(object["password"] == nil)
        #expect(proxy.profilePayload[ProxyTunnelConfiguration.Keys.credentialReference] as? String == proxy.id.uuidString)
        #expect(proxy.profilePayload[ProxyTunnelConfiguration.Keys.username] == nil)
        #expect(proxy.profilePayload[ProxyTunnelConfiguration.Keys.password] == nil)
    }
}
