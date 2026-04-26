//
//  ProxyBenchmarkService.swift
//  Proxyy
//
//  Created by Fruvs on 3/15/26.
//

import Foundation
import Network

private enum BenchmarkRuntime {
    static let headerLimit = 64 * 1_024
    static let bodyLimit = 1_024 * 1_024
    static let chunkSize = 16 * 1_024
}

actor ProxyBenchmarkService {
    static let shared = ProxyBenchmarkService()

    private let ipURL = URL(string: "http://api.ipify.org/")!
    private let speedURL = URL(string: "http://cachefly.cachefly.net/100kb.test")!
    private var locationCache: [String: ProxyLocation] = [:]
    private var lastLocationLookupAt: Date?

    func benchmark(_ proxy: ProxyEndpoint) async -> ProxyBenchmark {
        do {
            let trace = try await fetchExitIP(for: proxy)
            let location = await location(for: trace.ipAddress)

            let speed = try? await measureDownloadSpeed(for: proxy)

            return ProxyBenchmark(
                schemaVersion: ProxyBenchmark.currentSchemaVersion,
                testedAt: Date(),
                latencyMilliseconds: trace.latencyMilliseconds,
                downloadMegabitsPerSecond: speed,
                exitIPAddress: trace.ipAddress,
                location: location,
                isReachable: true,
                failureReason: nil
            )
        } catch {
            return ProxyBenchmark(
                schemaVersion: ProxyBenchmark.currentSchemaVersion,
                testedAt: Date(),
                latencyMilliseconds: nil,
                downloadMegabitsPerSecond: nil,
                exitIPAddress: nil,
                location: nil,
                isReachable: false,
                failureReason: error.localizedDescription
            )
        }
    }

    private func fetchExitIP(for proxy: ProxyEndpoint) async throws -> TraceResult {
        let startedAt = Date()
        let body = try await ProxyHTTPBenchmarkClient.fetch(url: ipURL, via: proxy)
        let ipAddress = String(decoding: body, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard ipAddress.isEmpty == false else {
            throw ProxyBenchmarkError.invalidTraceResponse
        }

        return TraceResult(
            ipAddress: ipAddress,
            latencyMilliseconds: Date().timeIntervalSince(startedAt) * 1_000
        )
    }

    private func measureDownloadSpeed(for proxy: ProxyEndpoint) async throws -> Double {
        let startedAt = Date()
        let body = try await ProxyHTTPBenchmarkClient.fetch(url: speedURL, via: proxy)
        let duration = max(Date().timeIntervalSince(startedAt), 0.001)
        return (Double(body.count) * 8) / duration / 1_000_000
    }

    private func location(for ipAddress: String) async -> ProxyLocation? {
        if let cached = locationCache[ipAddress] {
            return cached
        }

        if let lastLocationLookupAt {
            let elapsed = Date().timeIntervalSince(lastLocationLookupAt)
            if elapsed < 1 {
                let remaining = UInt64((1 - elapsed) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: remaining)
            }
        }

        lastLocationLookupAt = Date()

        guard let encodedIP = ipAddress.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://ipwho.is/\(encodedIP)") else {
            return nil
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                (object["success"] as? Bool) == true,
                let country = object["country"] as? String,
                country.isEmpty == false
            else {
                return nil
            }

            let location = ProxyLocation(
                city: object["city"] as? String,
                region: object["region"] as? String,
                country: country,
                countryCode: object["country_code"] as? String
            )

            locationCache[ipAddress] = location
            return location
        } catch {
            return nil
        }
    }
}

private struct TraceResult: Sendable {
    let ipAddress: String
    let latencyMilliseconds: Double
}

private enum ProxyBenchmarkError: LocalizedError {
    case invalidResponse
    case invalidTraceResponse
    case badStatusCode(Int)
    case unsupportedScheme
    case invalidPort
    case headerTooLarge
    case invalidTarget(String)
    case socksHandshakeFailed
    case socksAuthenticationRejected
    case socksConnectRejected
    case noHTTPResponse

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The proxy test returned an unreadable response."
        case .invalidTraceResponse:
            return "The proxy test did not return an exit IP address."
        case .badStatusCode(let statusCode):
            return "The proxy test returned HTTP \(statusCode)."
        case .unsupportedScheme:
            return "The proxy type is not supported by the benchmark runner."
        case .invalidPort:
            return "The proxy port is invalid."
        case .headerTooLarge:
            return "The proxy response headers were too large."
        case .invalidTarget(let target):
            return "The benchmark target \(target) is invalid."
        case .socksHandshakeFailed:
            return "The SOCKS proxy rejected the benchmark handshake."
        case .socksAuthenticationRejected:
            return "The SOCKS proxy rejected the username or password."
        case .socksConnectRejected:
            return "The SOCKS proxy could not reach the benchmark target."
        case .noHTTPResponse:
            return "The proxy closed the benchmark connection before a response arrived."
        }
    }
}

private enum ProxyHTTPBenchmarkClient {
    static func fetch(url: URL, via proxy: ProxyEndpoint) async throws -> Data {
        guard let host = url.host else {
            throw ProxyBenchmarkError.invalidTarget(url.absoluteString)
        }

        switch proxy.scheme {
        case .http, .https:
            let socket = try makeHTTPProxySocket(for: proxy)
            defer { socket.cancel() }

            try await socket.start()
            let request = makeRequestData(
                url: url,
                absoluteForm: true,
                proxyAuthorization: basicAuthorizationHeader(for: proxy)
            )
            try await socket.send(request)
            return try await readResponseBody(from: socket)

        case .socks, .socks4, .socks5:
            let socket = try await openSOCKSTunnel(
                for: proxy,
                targetHost: host,
                targetPort: url.port ?? 80
            )
            defer { socket.cancel() }

            let request = makeRequestData(
                url: url,
                absoluteForm: false,
                proxyAuthorization: nil
            )
            try await socket.send(request)
            return try await readResponseBody(from: socket)

        case .unknown:
            throw ProxyBenchmarkError.unsupportedScheme
        }
    }

    private static func makeHTTPProxySocket(for proxy: ProxyEndpoint) throws -> BenchmarkSocket {
        let parameters: NWParameters

        if proxy.scheme == .https {
            parameters = NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options())
        } else {
            parameters = NWParameters.tcp
        }

        return try BenchmarkSocket(host: proxy.host, port: proxy.port, parameters: parameters)
    }

    private static func openSOCKSTunnel(
        for proxy: ProxyEndpoint,
        targetHost: String,
        targetPort: Int
    ) async throws -> BenchmarkSocket {
        switch proxy.scheme {
        case .socks4:
            let socket = try BenchmarkSocket(host: proxy.host, port: proxy.port, parameters: .tcp)
            try await socket.start()
            try await authenticateSOCKS4(
                socket: socket,
                userID: proxy.username,
                targetHost: targetHost,
                targetPort: targetPort
            )
            return socket

        case .socks5:
            let socket = try BenchmarkSocket(host: proxy.host, port: proxy.port, parameters: .tcp)
            try await socket.start()
            try await authenticateSOCKS5(
                socket: socket,
                username: proxy.username,
                password: proxy.password,
                targetHost: targetHost,
                targetPort: targetPort
            )
            return socket

        case .socks:
            let socket = try BenchmarkSocket(host: proxy.host, port: proxy.port, parameters: .tcp)
            do {
                try await socket.start()
                try await authenticateSOCKS5(
                    socket: socket,
                    username: proxy.username,
                    password: proxy.password,
                    targetHost: targetHost,
                    targetPort: targetPort
                )
                return socket
            } catch {
                socket.cancel()

                guard proxy.password == nil else {
                    throw error
                }

                let fallback = try BenchmarkSocket(host: proxy.host, port: proxy.port, parameters: .tcp)
                try await fallback.start()
                try await authenticateSOCKS4(
                    socket: fallback,
                    userID: proxy.username,
                    targetHost: targetHost,
                    targetPort: targetPort
                )
                return fallback
            }

        default:
            throw ProxyBenchmarkError.unsupportedScheme
        }
    }

    private static func authenticateSOCKS5(
        socket: BenchmarkSocket,
        username: String?,
        password: String?,
        targetHost: String,
        targetPort: Int
    ) async throws {
        let methods: [UInt8] = (username != nil || password != nil) ? [0x00, 0x02] : [0x00]
        try await socket.send(Data([0x05, UInt8(methods.count)] + methods))

        let methodResponse = try await socket.readExact(length: 2)
        guard methodResponse.count == 2, methodResponse[0] == 0x05, methodResponse[1] != 0xFF else {
            throw ProxyBenchmarkError.socksHandshakeFailed
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
                throw ProxyBenchmarkError.socksAuthenticationRejected
            }

            var auth = Data([0x01, UInt8(usernameData.count)])
            auth.append(usernameData)
            auth.append(UInt8(passwordData.count))
            auth.append(passwordData)

            try await socket.send(auth)
            let authResponse = try await socket.readExact(length: 2)
            guard authResponse.count == 2, authResponse[1] == 0x00 else {
                throw ProxyBenchmarkError.socksAuthenticationRejected
            }
        }

        var connectRequest = Data([0x05, 0x01, 0x00])
        try appendSOCKSAddress(targetHost, to: &connectRequest)
        connectRequest.append(contentsOf: [UInt8(targetPort >> 8), UInt8(targetPort & 0xFF)])
        try await socket.send(connectRequest)

        let responsePrefix = try await socket.readExact(length: 4)
        guard responsePrefix.count == 4, responsePrefix[0] == 0x05 else {
            throw ProxyBenchmarkError.socksHandshakeFailed
        }

        guard responsePrefix[1] == 0x00 else {
            throw ProxyBenchmarkError.socksConnectRejected
        }

        let remainingBytes: Int
        switch responsePrefix[3] {
        case 0x01:
            remainingBytes = 4 + 2
        case 0x03:
            let length = try await socket.readExact(length: 1)
            remainingBytes = Int(length[0]) + 2
        case 0x04:
            remainingBytes = 16 + 2
        default:
            throw ProxyBenchmarkError.socksHandshakeFailed
        }

        _ = try await socket.readExact(length: remainingBytes)
    }

    private static func authenticateSOCKS4(
        socket: BenchmarkSocket,
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

        if let ipv4Address = ipv4Bytes(targetHost) {
            request.append(contentsOf: ipv4Address)
        } else {
            request.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        }

        if let userID {
            request.append(Data(userID.utf8))
        }

        request.append(0x00)

        if ipv4Bytes(targetHost) == nil, let hostData = targetHost.data(using: .utf8) {
            request.append(hostData)
            request.append(0x00)
        }

        try await socket.send(request)

        let response = try await socket.readExact(length: 8)
        guard response.count == 8, response[0] == 0x00 else {
            throw ProxyBenchmarkError.socksHandshakeFailed
        }

        guard response[1] == 0x5A else {
            throw ProxyBenchmarkError.socksConnectRejected
        }
    }

    private static func appendSOCKSAddress(_ host: String, to data: inout Data) throws {
        if let ipv4Address = ipv4Bytes(host) {
            data.append(0x01)
            data.append(contentsOf: ipv4Address)
            return
        }

        if let ipv6Address = ipv6Bytes(host) {
            data.append(0x04)
            data.append(contentsOf: ipv6Address)
            return
        }

        guard let hostData = host.data(using: .utf8), hostData.count < 256 else {
            throw ProxyBenchmarkError.invalidTarget(host)
        }

        data.append(0x03)
        data.append(UInt8(hostData.count))
        data.append(hostData)
    }

    private static func makeRequestData(
        url: URL,
        absoluteForm: Bool,
        proxyAuthorization: String?
    ) -> Data {
        let path = url.path.isEmpty ? "/" : url.path
        let target = absoluteForm ? url.absoluteString : path + (url.query.map { "?\($0)" } ?? "")
        let host = url.host ?? ""

        var lines = [
            "GET \(target) HTTP/1.0",
            "Host: \(host)",
            "Connection: close",
            "User-Agent: Proxyy/1.0"
        ]

        if let proxyAuthorization {
            lines.append("Proxy-Authorization: \(proxyAuthorization)")
        }

        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    private static func readResponseBody(from socket: BenchmarkSocket) async throws -> Data {
        let responseData = try await socket.readResponse(limit: BenchmarkRuntime.bodyLimit)
        let response = try HTTPBenchmarkResponse(data: responseData)

        guard (200...299).contains(response.statusCode) else {
            throw ProxyBenchmarkError.badStatusCode(response.statusCode)
        }

        return response.body
    }

    private static func basicAuthorizationHeader(for proxy: ProxyEndpoint) -> String? {
        guard let username = proxy.username, let password = proxy.password else {
            return nil
        }

        let token = Data("\(username):\(password)".utf8).base64EncodedString()
        return "Basic \(token)"
    }
}

private struct HTTPBenchmarkResponse {
    let statusCode: Int
    let body: Data

    init(data: Data) throws {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator) else {
            throw ProxyBenchmarkError.invalidResponse
        }

        let headerData = data[..<range.lowerBound]
        let bodyData = data[range.upperBound...]

        guard
            let headerText = String(data: headerData, encoding: .utf8)
                ?? String(data: headerData, encoding: .isoLatin1)
        else {
            throw ProxyBenchmarkError.invalidResponse
        }

        guard let statusLine = headerText.components(separatedBy: "\r\n").first else {
            throw ProxyBenchmarkError.invalidResponse
        }

        let parts = statusLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, let statusCode = Int(parts[1]) else {
            throw ProxyBenchmarkError.invalidResponse
        }

        self.statusCode = statusCode
        body = Data(bodyData)
    }
}

private final class BenchmarkSocket: @unchecked Sendable {
    nonisolated private let connection: NWConnection
    nonisolated private let queue = DispatchQueue(label: "fruvs.proxyy.benchmark.socket.\(UUID().uuidString)")
    nonisolated private let startLock = NSLock()
    nonisolated(unsafe) private var hasStarted = false
    nonisolated private let startGate = BenchmarkResumeGate()

    init(host: String, port: Int, parameters: NWParameters) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw ProxyBenchmarkError.invalidPort
        }

        connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
    }

    nonisolated func start() async throws {
        let shouldStart = startLock.sync {
            let value = !hasStarted
            hasStarted = true
            return value
        }

        guard shouldStart else { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.finishStart(with: .success(()), continuation: continuation)
                case .failed(let error):
                    self?.finishStart(with: .failure(error), continuation: continuation)
                case .cancelled:
                    self?.finishStart(with: .failure(ProxyBenchmarkError.invalidResponse), continuation: continuation)
                default:
                    break
                }
            }

            connection.start(queue: queue)
        }
    }

    nonisolated func cancel() {
        connection.cancel()
    }

    nonisolated func send(_ data: Data) async throws {
        guard data.isEmpty == false else { return }

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

    nonisolated func readExact(length: Int) async throws -> Data {
        var data = Data()

        while data.count < length {
            guard let chunk = try await receiveChunk(maximumLength: length - data.count) else {
                throw ProxyBenchmarkError.invalidResponse
            }

            if chunk.isEmpty == false {
                data.append(chunk)
            }
        }

        return data
    }

    nonisolated func readResponse(limit: Int) async throws -> Data {
        var buffer = Data()

        while !Task.isCancelled {
            guard let chunk = try await receiveChunk(maximumLength: BenchmarkRuntime.chunkSize) else {
                break
            }

            if chunk.isEmpty == false {
                buffer.append(chunk)
            }

            if buffer.count > limit {
                throw ProxyBenchmarkError.headerTooLarge
            }
        }

        guard buffer.isEmpty == false else {
            throw ProxyBenchmarkError.noHTTPResponse
        }

        return buffer
    }

    nonisolated private func receiveChunk(maximumLength: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: maximumLength
            ) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                if let data, data.isEmpty == false {
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

    nonisolated private func finishStart(
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

private final class BenchmarkResumeGate: @unchecked Sendable {
    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var hasResumed = false

    nonisolated func resume(_ action: () -> Void) {
        lock.lock()
        defer { lock.unlock() }

        guard hasResumed == false else { return }
        hasResumed = true
        action()
    }
}

private func ipv4Bytes(_ host: String) -> [UInt8]? {
    var address = in_addr()
    let result = host.withCString { inet_pton(AF_INET, $0, &address) }
    guard result == 1 else {
        return nil
    }

    return withUnsafeBytes(of: address.s_addr.bigEndian, Array.init)
}

private func ipv6Bytes(_ host: String) -> [UInt8]? {
    var address = in6_addr()
    let result = host.withCString { inet_pton(AF_INET6, $0, &address) }
    guard result == 1 else {
        return nil
    }

    return withUnsafeBytes(of: address.__u6_addr.__u6_addr8, Array.init)
}

private extension NSLock {
    nonisolated func sync<T>(_ work: () -> T) -> T {
        lock()
        defer { unlock() }
        return work()
    }
}
