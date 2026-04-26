//
//  PacketTunnelProvider.swift
//  ProxyyTunnel
//
//  Created by Fruvs on 3/15/26.
//

import Foundation
import Network
import NetworkExtension
import Security

private enum TunnelRuntime {
    static let loopbackHost = "127.0.0.1"
    static let loopbackPort = 8_191
    static let mtu = 1_500
    static let headerLimit = 64 * 1_024
    static let chunkSize = 16 * 1_024
}

private struct TunnelCredentials {
    let username: String?
    let password: String?

    nonisolated init?(data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }

        username = object["username"]
        password = object["password"]
    }
}

private enum TunnelCredentialStore {
    nonisolated private static let service = "fruvs.Proxyy.proxy.credentials"
    nonisolated private static let accessGroup = "985XZHBX3T.fruvs.Proxyy"

    nonisolated static func load(reference: String) -> TunnelCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let credentials = TunnelCredentials(data: data) else {
            return nil
        }

        return credentials
    }
}

private struct ProviderProxyConfiguration {
    let scheme: ProxyScheme
    let host: String
    let port: Int
    let label: String
    let credentialReference: String?
    let username: String?
    let password: String?

    init?(dictionary: [String: Any]) {
        guard
            let schemeValue = dictionary[ProxyTunnelConfiguration.Keys.scheme] as? String,
            let scheme = ProxyScheme(rawValue: schemeValue),
            let host = dictionary[ProxyTunnelConfiguration.Keys.host] as? String,
            let port = dictionary[ProxyTunnelConfiguration.Keys.port] as? Int
        else {
            return nil
        }

        self.scheme = scheme
        self.host = host
        self.port = port
        self.label = dictionary[ProxyTunnelConfiguration.Keys.label] as? String ?? host
        self.credentialReference = dictionary[ProxyTunnelConfiguration.Keys.credentialReference] as? String

        let credentials = credentialReference.flatMap(TunnelCredentialStore.load)
        self.username = credentials?.username ?? dictionary[ProxyTunnelConfiguration.Keys.username] as? String
        self.password = credentials?.password ?? dictionary[ProxyTunnelConfiguration.Keys.password] as? String
    }

    var hasCredentials: Bool {
        username != nil || password != nil
    }

    var basicAuthorizationHeader: String? {
        guard let username, let password else {
            return nil
        }

        let token = Data("\(username):\(password)".utf8).base64EncodedString()
        return "Basic \(token)"
    }
}

private enum TunnelProviderError: LocalizedError {
    case missingConfiguration
    case unsupportedScheme(String)
    case invalidPort
    case invalidProxyRequest
    case headerTooLarge
    case invalidTarget(String)
    case socksHandshakeFailed
    case socksAuthenticationRejected
    case socksConnectRejected
    case noHTTPResponse

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "No proxy configuration was provided to the tunnel."
        case .unsupportedScheme(let scheme):
            return "The proxy scheme \(scheme) is not supported by this packet tunnel."
        case .invalidPort:
            return "The configured proxy port is invalid."
        case .invalidProxyRequest:
            return "The local proxy bridge received an invalid request."
        case .headerTooLarge:
            return "The proxy request headers exceeded the supported size."
        case .invalidTarget(let target):
            return "The requested destination \(target) could not be resolved."
        case .socksHandshakeFailed:
            return "The SOCKS proxy rejected the connection handshake."
        case .socksAuthenticationRejected:
            return "The SOCKS proxy rejected the supplied username or password."
        case .socksConnectRejected:
            return "The SOCKS proxy could not connect to the requested destination."
        case .noHTTPResponse:
            return "The upstream proxy closed the connection before sending a response."
        }
    }
}

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var bridge: LocalProxyBridge?

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        Task {
            do {
                let configuration = try resolveConfiguration(options: options)
                guard configuration.scheme != .unknown else {
                    throw TunnelProviderError.unsupportedScheme(configuration.scheme.rawValue)
                }

                let bridge = try LocalProxyBridge(configuration: configuration)
                try await bridge.start()

                do {
                    try await applyTunnelSettings(makeNetworkSettings())
                    self.bridge = bridge
                    completionHandler(nil)
                } catch {
                    await bridge.stop()
                    completionHandler(error)
                }
            } catch {
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        Task {
            await bridge?.stop()
            bridge = nil
            completionHandler()
        }
    }

    private func resolveConfiguration(options: [String: NSObject]?) throws -> ProviderProxyConfiguration {
        if let options,
           let configuration = ProviderProxyConfiguration(dictionary: options) {
            return configuration
        }

        let providerConfiguration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration

        if let providerConfiguration,
           let configuration = ProviderProxyConfiguration(dictionary: providerConfiguration) {
            return configuration
        }

        throw TunnelProviderError.missingConfiguration
    }

    private func applyTunnelSettings(_ settings: NEPacketTunnelNetworkSettings) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            setTunnelNetworkSettings(settings) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func makeNetworkSettings() -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: TunnelRuntime.loopbackHost)
        let ipv4Settings = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.255"])
        ipv4Settings.includedRoutes = []
        settings.ipv4Settings = ipv4Settings
        settings.proxySettings = makeLoopbackProxySettings()
        settings.mtu = TunnelRuntime.mtu as NSNumber
        return settings
    }

    private func makeLoopbackProxySettings() -> NEProxySettings {
        let proxySettings = NEProxySettings()
        let proxyServer = NEProxyServer(address: TunnelRuntime.loopbackHost, port: TunnelRuntime.loopbackPort)

        proxySettings.excludeSimpleHostnames = true
        proxySettings.matchDomains = [""]
        proxySettings.exceptionList = [
            "localhost",
            "127.0.0.1",
            "*.local"
        ]
        proxySettings.httpEnabled = true
        proxySettings.httpServer = proxyServer
        proxySettings.httpsEnabled = true
        proxySettings.httpsServer = proxyServer
        return proxySettings
    }
}

private final class LocalProxyBridge: @unchecked Sendable {
    private let configuration: ProviderProxyConfiguration
    private let listener: NWListener
    private let listenerQueue = DispatchQueue(label: "fruvs.proxyy.bridge.listener")
    private let sessionLock = NSLock()
    private var sessions: [UUID: Task<Void, Never>] = [:]
    private let startGate = ResumeGate()

    init(configuration: ProviderProxyConfiguration) throws {
        self.configuration = configuration

        guard let port = NWEndpoint.Port(rawValue: UInt16(TunnelRuntime.loopbackPort)) else {
            throw TunnelProviderError.invalidPort
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(TunnelRuntime.loopbackHost),
            port: port
        )

        listener = try NWListener(using: parameters)
    }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                self?.accept(connection)
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    switch state {
                    case .ready:
                        self?.startGate.resume {
                            continuation.resume()
                        }
                    case .failed(let error):
                        self?.startGate.resume {
                            continuation.resume(throwing: error)
                        }
                    case .cancelled:
                        self?.startGate.resume {
                            continuation.resume(throwing: TunnelProviderError.invalidProxyRequest)
                        }
                    default:
                        break
                    }
                }
            }

            listener.start(queue: listenerQueue)
        }
    }

    func stop() async {
        listener.cancel()

        let activeSessions = sessionLock.sync {
            let currentSessions = Array(sessions.values)
            sessions.removeAll()
            return currentSessions
        }

        for task in activeSessions {
            task.cancel()
        }
    }

    private func accept(_ connection: NWConnection) {
        let sessionID = UUID()
        let task = Task { [weak self] in
            defer {
                self?.removeSession(sessionID)
            }

            let client = ProxySocket(connection: connection)

            do {
                let session = ProxyBridgeSession(client: client, configuration: self?.configuration)
                try await session.run()
            } catch {
                client.cancel()
            }
        }

        sessionLock.sync {
            sessions[sessionID] = task
        }
    }

    private func removeSession(_ sessionID: UUID) {
        _ = sessionLock.sync {
            sessions.removeValue(forKey: sessionID)
        }
    }
}

private struct ProxyBridgeSession {
    let client: ProxySocket
    let configuration: ProviderProxyConfiguration?

    func run() async throws {
        guard let configuration else {
            throw TunnelProviderError.missingConfiguration
        }

        try await client.start()
        let requestData = try await client.readHeaders(limit: TunnelRuntime.headerLimit)
        let request = try HTTPProxyRequest(data: requestData)

        if request.isConnect {
            try await handleConnect(request: request, configuration: configuration)
        } else {
            try await handleStandardRequest(request: request, configuration: configuration)
        }
    }

    private func handleConnect(
        request: HTTPProxyRequest,
        configuration: ProviderProxyConfiguration
    ) async throws {
        let destination = try request.destination

        switch configuration.scheme {
        case .http, .https:
            let upstream = try makeUpstreamProxyConnection(for: configuration)
            try await upstream.start()

            try await upstream.send(request.serializedForHTTPProxy(authHeader: configuration.basicAuthorizationHeader))
            let responseData = try await upstream.readHeaders(limit: TunnelRuntime.headerLimit)
            let response = try HTTPProxyResponse(data: responseData)
            try await client.send(response.rawData)

            guard response.isSuccessful else {
                upstream.cancel()
                client.cancel()
                return
            }

            if !request.bodyRemainder.isEmpty {
                try await upstream.send(request.bodyRemainder)
            }

            try await relay(client, upstream)

        case .socks4, .socks5, .socks:
            let upstream = try await openSOCKSTunnel(
                configuration: configuration,
                targetHost: destination.host,
                targetPort: destination.port
            )

            try await client.send(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))

            if !request.bodyRemainder.isEmpty {
                try await upstream.send(request.bodyRemainder)
            }

            try await relay(client, upstream)

        case .unknown:
            throw TunnelProviderError.unsupportedScheme(configuration.scheme.rawValue)
        }
    }

    private func handleStandardRequest(
        request: HTTPProxyRequest,
        configuration: ProviderProxyConfiguration
    ) async throws {
        switch configuration.scheme {
        case .http, .https:
            let upstream = try makeUpstreamProxyConnection(for: configuration)
            try await upstream.start()
            try await upstream.send(request.serializedForHTTPProxy(authHeader: configuration.basicAuthorizationHeader))
            try await relay(client, upstream)

        case .socks4, .socks5, .socks:
            let destination = try request.destination
            let upstream = try await openSOCKSTunnel(
                configuration: configuration,
                targetHost: destination.host,
                targetPort: destination.port
            )
            try await upstream.send(request.serializedForOriginServer())
            try await relay(client, upstream)

        case .unknown:
            throw TunnelProviderError.unsupportedScheme(configuration.scheme.rawValue)
        }
    }

    private func makeUpstreamProxyConnection(for configuration: ProviderProxyConfiguration) throws -> ProxySocket {
        let parameters: NWParameters

        switch configuration.scheme {
        case .https:
            parameters = NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options())
        default:
            parameters = NWParameters.tcp
        }

        return try ProxySocket(
            host: configuration.host,
            port: configuration.port,
            parameters: parameters
        )
    }

    private func openSOCKSTunnel(
        configuration: ProviderProxyConfiguration,
        targetHost: String,
        targetPort: Int
    ) async throws -> ProxySocket {
        let upstream = try ProxySocket(
            host: configuration.host,
            port: configuration.port,
            parameters: NWParameters.tcp
        )

        try await upstream.start()

        switch configuration.scheme {
        case .socks4:
            try await authenticateSOCKS4(
                upstream: upstream,
                userID: configuration.username,
                targetHost: targetHost,
                targetPort: targetPort
            )
        case .socks5:
            try await authenticateSOCKS5(
                upstream: upstream,
                username: configuration.username,
                password: configuration.password,
                targetHost: targetHost,
                targetPort: targetPort
            )
        case .socks:
            do {
                try await authenticateSOCKS5(
                    upstream: upstream,
                    username: configuration.username,
                    password: configuration.password,
                    targetHost: targetHost,
                    targetPort: targetPort
                )
            } catch {
                upstream.cancel()

                guard configuration.password == nil else {
                    throw error
                }

                let fallback = try ProxySocket(
                    host: configuration.host,
                    port: configuration.port,
                    parameters: NWParameters.tcp
                )

                try await fallback.start()
                try await authenticateSOCKS4(
                    upstream: fallback,
                    userID: configuration.username,
                    targetHost: targetHost,
                    targetPort: targetPort
                )
                return fallback
            }
        default:
            throw TunnelProviderError.unsupportedScheme(configuration.scheme.rawValue)
        }

        return upstream
    }

    private func authenticateSOCKS5(
        upstream: ProxySocket,
        username: String?,
        password: String?,
        targetHost: String,
        targetPort: Int
    ) async throws {
        let methods: [UInt8]
        if username != nil || password != nil {
            methods = [0x00, 0x02]
        } else {
            methods = [0x00]
        }

        try await upstream.send(Data([0x05, UInt8(methods.count)] + methods))
        let methodResponse = try await upstream.readExact(length: 2)

        guard methodResponse.count == 2, methodResponse[0] == 0x05, methodResponse[1] != 0xFF else {
            throw TunnelProviderError.socksHandshakeFailed
        }

        if methodResponse[1] == 0x02 {
            guard
                let username,
                let password,
                let usernameData = username.data(using: .utf8),
                let passwordData = password.data(using: .utf8),
                usernameData.count < 256,
                passwordData.count < 256
            else {
                throw TunnelProviderError.socksAuthenticationRejected
            }

            var auth = Data([0x01, UInt8(usernameData.count)])
            auth.append(usernameData)
            auth.append(UInt8(passwordData.count))
            auth.append(passwordData)

            try await upstream.send(auth)

            let authResponse = try await upstream.readExact(length: 2)
            guard authResponse.count == 2, authResponse[1] == 0x00 else {
                throw TunnelProviderError.socksAuthenticationRejected
            }
        }

        var connectRequest = Data([0x05, 0x01, 0x00])
        try appendSOCKSAddress(targetHost, to: &connectRequest)
        connectRequest.append(contentsOf: [UInt8(targetPort >> 8), UInt8(targetPort & 0xFF)])

        try await upstream.send(connectRequest)

        let responsePrefix = try await upstream.readExact(length: 4)
        guard responsePrefix.count == 4, responsePrefix[0] == 0x05 else {
            throw TunnelProviderError.socksHandshakeFailed
        }

        guard responsePrefix[1] == 0x00 else {
            throw TunnelProviderError.socksConnectRejected
        }

        let remainingBytes: Int
        switch responsePrefix[3] {
        case 0x01:
            remainingBytes = 4 + 2
        case 0x03:
            let length = try await upstream.readExact(length: 1)
            remainingBytes = Int(length[0]) + 2
        case 0x04:
            remainingBytes = 16 + 2
        default:
            throw TunnelProviderError.socksHandshakeFailed
        }

        _ = try await upstream.readExact(length: remainingBytes)
    }

    private func authenticateSOCKS4(
        upstream: ProxySocket,
        userID: String?,
        targetHost: String,
        targetPort: Int
    ) async throws {
        var request = Data([
            0x04,
            0x01,
            UInt8(targetPort >> 8),
            UInt8(targetPort & 0xFF)
        ])

        let hostData = targetHost.data(using: .utf8)
        if let ipv4Address = IPv4Bytes(targetHost) {
            request.append(ipv4Address, count: ipv4Address.count)
        } else {
            request.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        }

        if let userID {
            request.append(Data(userID.utf8))
        }

        request.append(0x00)

        if IPv4Bytes(targetHost) == nil, let hostData {
            request.append(hostData)
            request.append(0x00)
        }

        try await upstream.send(request)

        let response = try await upstream.readExact(length: 8)
        guard response.count == 8, response[0] == 0x00 else {
            throw TunnelProviderError.socksHandshakeFailed
        }

        guard response[1] == 0x5A else {
            throw TunnelProviderError.socksConnectRejected
        }
    }

    private func appendSOCKSAddress(_ host: String, to data: inout Data) throws {
        if let ipv4Address = IPv4Bytes(host) {
            data.append(0x01)
            data.append(ipv4Address, count: ipv4Address.count)
            return
        }

        if let ipv6Address = IPv6Bytes(host) {
            data.append(0x04)
            data.append(ipv6Address, count: ipv6Address.count)
            return
        }

        guard let hostData = host.data(using: .utf8), hostData.count < 256 else {
            throw TunnelProviderError.invalidTarget(host)
        }

        data.append(0x03)
        data.append(UInt8(hostData.count))
        data.append(hostData)
    }

    private func relay(_ client: ProxySocket, _ upstream: ProxySocket) async throws {
        defer {
            client.cancel()
            upstream.cancel()
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await forward(from: client, to: upstream)
            }

            group.addTask {
                try await forward(from: upstream, to: client)
            }

            do {
                _ = try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private func forward(from source: ProxySocket, to destination: ProxySocket) async throws {
        while !Task.isCancelled {
            guard let chunk = try await source.receiveChunk(maximumLength: TunnelRuntime.chunkSize) else {
                return
            }

            guard !chunk.isEmpty else {
                continue
            }

            try await destination.send(chunk)
        }
    }
}

private struct HTTPProxyRequest {
    struct Header {
        let name: String
        let value: String
    }

    let method: String
    let target: String
    let version: String
    let headers: [Header]
    let bodyRemainder: Data

    init(data: Data) throws {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else {
            throw TunnelProviderError.invalidProxyRequest
        }

        let headerData = data[..<headerRange.lowerBound]
        bodyRemainder = data[headerRange.upperBound...]

        guard
            let headerText = String(data: headerData, encoding: .utf8)
                ?? String(data: headerData, encoding: .isoLatin1)
        else {
            throw TunnelProviderError.invalidProxyRequest
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw TunnelProviderError.invalidProxyRequest
        }

        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard requestParts.count >= 3 else {
            throw TunnelProviderError.invalidProxyRequest
        }

        method = String(requestParts[0])
        target = String(requestParts[1])
        version = String(requestParts[2])
        headers = lines.dropFirst().compactMap { line in
            guard let colonIndex = line.firstIndex(of: ":") else {
                return nil
            }

            let name = String(line[..<colonIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return Header(name: name, value: value)
        }
    }

    var isConnect: Bool {
        method.caseInsensitiveCompare("CONNECT") == .orderedSame
    }

    var destination: (host: String, port: Int) {
        get throws {
            if isConnect {
                return try Self.parseAuthority(target, defaultPort: 443)
            }

            if target.contains("://"),
               let components = URLComponents(string: target),
               let host = components.host {
                let port = components.port ?? Self.defaultPort(for: components.scheme)
                return (host, port)
            }

            if let hostHeader = headerValue(named: "Host") {
                return try Self.parseAuthority(hostHeader, defaultPort: 80)
            }

            throw TunnelProviderError.invalidTarget(target)
        }
    }

    func serializedForHTTPProxy(authHeader: String?) -> Data {
        let requestTarget: String
        if isConnect {
            requestTarget = target
        } else if target.contains("://") {
            requestTarget = target
        } else if let hostHeader = headerValue(named: "Host") {
            requestTarget = "http://\(hostHeader)\(target)"
        } else {
            requestTarget = target
        }

        let outgoingHeaders = headers.filter {
            !$0.name.equalsCaseInsensitively("Proxy-Authorization")
        }

        return serialize(
            method: method,
            target: requestTarget,
            version: version,
            headers: outgoingHeaders,
            extraHeader: authHeader.map { Header(name: "Proxy-Authorization", value: $0) },
            bodyRemainder: bodyRemainder
        )
    }

    func serializedForOriginServer() -> Data {
        let requestTarget: String
        if target.contains("://"),
           let components = URLComponents(string: target) {
            var path = components.percentEncodedPath
            if path.isEmpty {
                path = "/"
            }

            if let query = components.percentEncodedQuery {
                path += "?\(query)"
            }

            requestTarget = path
        } else {
            requestTarget = target.isEmpty ? "/" : target
        }

        let outgoingHeaders = headers.filter {
            !$0.name.equalsCaseInsensitively("Proxy-Authorization")
                && !$0.name.equalsCaseInsensitively("Proxy-Connection")
        }

        return serialize(
            method: method,
            target: requestTarget,
            version: version,
            headers: outgoingHeaders,
            extraHeader: nil,
            bodyRemainder: bodyRemainder
        )
    }

    private func headerValue(named name: String) -> String? {
        headers.first { $0.name.equalsCaseInsensitively(name) }?.value
    }

    private func serialize(
        method: String,
        target: String,
        version: String,
        headers: [Header],
        extraHeader: Header?,
        bodyRemainder: Data
    ) -> Data {
        var lines = ["\(method) \(target) \(version)"]
        for header in headers {
            lines.append("\(header.name): \(header.value)")
        }

        if let extraHeader {
            lines.append("\(extraHeader.name): \(extraHeader.value)")
        }

        var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        data.append(bodyRemainder)
        return data
    }

    private static func parseAuthority(_ authority: String, defaultPort: Int) throws -> (host: String, port: Int) {
        if authority.contains("://"),
           let components = URLComponents(string: authority),
           let host = components.host {
            return (host, components.port ?? defaultPort)
        }

        guard let components = URLComponents(string: "http://\(authority)"),
              let host = components.host else {
            throw TunnelProviderError.invalidTarget(authority)
        }

        return (host, components.port ?? defaultPort)
    }

    private static func defaultPort(for scheme: String?) -> Int {
        switch scheme?.lowercased() {
        case "https":
            return 443
        default:
            return 80
        }
    }
}

private struct HTTPProxyResponse {
    let statusCode: Int
    let rawData: Data

    init(data: Data) throws {
        let separator = Data("\r\n".utf8)
        guard let lineRange = data.range(of: separator) else {
            throw TunnelProviderError.noHTTPResponse
        }

        let statusLineData = data[..<lineRange.lowerBound]
        guard
            let statusLine = String(data: statusLineData, encoding: .utf8)
                ?? String(data: statusLineData, encoding: .isoLatin1)
        else {
            throw TunnelProviderError.noHTTPResponse
        }

        let parts = statusLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, let statusCode = Int(parts[1]) else {
            throw TunnelProviderError.noHTTPResponse
        }

        self.statusCode = statusCode
        rawData = data
    }

    var isSuccessful: Bool {
        (200...299).contains(statusCode)
    }
}

private final class ProxySocket: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "fruvs.proxyy.bridge.socket.\(UUID().uuidString)")
    private let startLock = NSLock()
    private var hasStarted = false
    private let startGate = ResumeGate()

    init(connection: NWConnection) {
        self.connection = connection
    }

    init(host: String, port: Int, parameters: NWParameters) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw TunnelProviderError.invalidPort
        }

        connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
    }

    func start() async throws {
        let shouldStart = startLock.sync {
            let shouldStart = !hasStarted
            hasStarted = true
            return shouldStart
        }

        guard shouldStart else {
            return
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    switch state {
                    case .ready:
                        self?.finishStart(with: .success(()), continuation: continuation)
                    case .failed(let error):
                        self?.finishStart(with: .failure(error), continuation: continuation)
                    case .cancelled:
                        self?.finishStart(with: .failure(TunnelProviderError.invalidProxyRequest), continuation: continuation)
                    default:
                        break
                    }
                }
            }

            connection.start(queue: queue)
        }
    }

    func cancel() {
        connection.cancel()
    }

    func send(_ data: Data) async throws {
        guard !data.isEmpty else {
            return
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func readHeaders(limit: Int) async throws -> Data {
        let terminator = Data("\r\n\r\n".utf8)
        var buffer = Data()

        while !Task.isCancelled {
            guard let chunk = try await receiveChunk(maximumLength: TunnelRuntime.chunkSize) else {
                throw TunnelProviderError.noHTTPResponse
            }

            if !chunk.isEmpty {
                buffer.append(chunk)
            }

            if buffer.range(of: terminator) != nil {
                return buffer
            }

            if buffer.count > limit {
                throw TunnelProviderError.headerTooLarge
            }
        }

        throw TunnelProviderError.invalidProxyRequest
    }

    func readExact(length: Int) async throws -> Data {
        var data = Data()

        while data.count < length {
            guard let chunk = try await receiveChunk(maximumLength: length - data.count) else {
                throw TunnelProviderError.invalidProxyRequest
            }

            guard !chunk.isEmpty else {
                continue
            }

            data.append(chunk)
        }

        return data
    }

    func receiveChunk(maximumLength: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: maximumLength
            ) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                    return
                }

                if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private func finishStart(
        with result: Result<Void, Error>,
        continuation: CheckedContinuation<Void, Error>
    ) {
        connection.stateUpdateHandler = nil
        startGate.resume {
            switch result {
            case .success:
                continuation.resume()
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }
}

private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false

    func resume(_ action: () -> Void) {
        lock.lock()
        defer { lock.unlock() }

        guard !hasResumed else {
            return
        }

        hasResumed = true
        action()
    }
}

private func IPv4Bytes(_ host: String) -> [UInt8]? {
    var address = in_addr()
    let result = host.withCString { inet_pton(AF_INET, $0, &address) }
    guard result == 1 else {
        return nil
    }

    return withUnsafeBytes(of: address.s_addr.bigEndian, Array.init)
}

private func IPv6Bytes(_ host: String) -> [UInt8]? {
    var address = in6_addr()
    let result = host.withCString { inet_pton(AF_INET6, $0, &address) }
    guard result == 1 else {
        return nil
    }

    return withUnsafeBytes(of: address.__u6_addr.__u6_addr8, Array.init)
}

private extension String {
    func equalsCaseInsensitively(_ other: String) -> Bool {
        caseInsensitiveCompare(other) == .orderedSame
    }
}

private extension NSLock {
    nonisolated func sync<T>(_ work: () -> T) -> T {
        lock()
        defer { unlock() }
        return work()
    }
}
