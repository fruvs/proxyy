//
//  ProxyTypeDetector.swift
//  Proxyy
//
//  Created by Fruvs on 3/15/26.
//

import Foundation
import Network

enum ProxyTypeDetector {
    static func detect(for proxy: ProxyEndpoint) async -> ProxyScheme {
        guard proxy.needsDetection else {
            return proxy.scheme
        }

        if await probeHTTP(proxy, tls: false) {
            return .http
        }

        if await probeHTTP(proxy, tls: true) {
            return .https
        }

        if await probeSOCKS5(proxy) {
            return .socks5
        }

        if await probeSOCKS4(proxy) {
            return .socks4
        }

        return .unknown
    }

    private static func probeHTTP(_ proxy: ProxyEndpoint, tls: Bool) async -> Bool {
        guard let request = httpProbeRequest(for: proxy) else {
            return false
        }

        do {
            let data = try await ConnectionProbe(host: proxy.host, port: proxy.port, tls: tls)
                .execute(payload: request)
            let response = String(decoding: data, as: UTF8.self).uppercased()
            return response.hasPrefix("HTTP/1.1") || response.hasPrefix("HTTP/1.0")
        } catch {
            return false
        }
    }

    private static func probeSOCKS5(_ proxy: ProxyEndpoint) async -> Bool {
        let methods: [UInt8]
        if proxy.hasCredentials {
            methods = [0x00, 0x02]
        } else {
            methods = [0x00]
        }

        let greeting = Data([0x05, UInt8(methods.count)] + methods)

        do {
            let probe = try ConnectionProbe(host: proxy.host, port: proxy.port, tls: false)
            let response = try await probe.execute(payload: greeting, minimumResponseBytes: 2, maximumResponseBytes: 2)

            guard response.count == 2, response[0] == 0x05, response[1] != 0xFF else {
                return false
            }

            guard response[1] == 0x02 else {
                return true
            }

            guard
                let usernameData = proxy.username?.data(using: .utf8),
                let passwordData = proxy.password?.data(using: .utf8),
                usernameData.count < 256,
                passwordData.count < 256
            else {
                return false
            }

            var auth = Data([0x01, UInt8(usernameData.count)])
            auth.append(usernameData)
            auth.append(UInt8(passwordData.count))
            auth.append(passwordData)

            let authResponse = try await probe.exchange(
                payload: auth,
                minimumResponseBytes: 2,
                maximumResponseBytes: 2
            )

            return authResponse.count == 2 && authResponse[1] == 0x00
        } catch {
            return false
        }
    }

    private static func probeSOCKS4(_ proxy: ProxyEndpoint) async -> Bool {
        let userBytes = Data((proxy.username ?? "").utf8)
        var request = Data([
            0x04,
            0x01,
            0x00,
            0x50,
            0x01,
            0x01,
            0x01,
            0x01
        ])
        request.append(userBytes)
        request.append(0x00)

        do {
            let response = try await ConnectionProbe(host: proxy.host, port: proxy.port, tls: false)
                .execute(payload: request, minimumResponseBytes: 8, maximumResponseBytes: 8)

            guard response.count == 8, response[0] == 0x00 else {
                return false
            }

            return (0x5A...0x5D).contains(response[1])
        } catch {
            return false
        }
    }

    private static func httpProbeRequest(for proxy: ProxyEndpoint) -> Data? {
        var lines = [
            "CONNECT example.com:443 HTTP/1.1",
            "Host: example.com:443",
            "Proxy-Connection: Keep-Alive"
        ]

        if let authorization = basicAuthorizationHeader(for: proxy) {
            lines.append("Proxy-Authorization: \(authorization)")
        }

        return (lines.joined(separator: "\r\n") + "\r\n\r\n").data(using: .utf8)
    }

    private static func basicAuthorizationHeader(for proxy: ProxyEndpoint) -> String? {
        guard let username = proxy.username, let password = proxy.password else {
            return nil
        }

        let token = Data("\(username):\(password)".utf8).base64EncodedString()
        return "Basic \(token)"
    }
}

private enum ConnectionProbeError: Error {
    case invalidPort
    case cancelled
    case noResponse
    case timeout
}

private final class ConnectionProbe: @unchecked Sendable {
    nonisolated private let connection: NWConnection
    nonisolated private let queue = DispatchQueue(label: "fruvs.proxyy.probe.\(UUID().uuidString)")
    nonisolated private let resumeGate = ResumeGate()

    deinit {
        connection.cancel()
    }

    nonisolated init(host: String, port: Int, tls: Bool) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw ConnectionProbeError.invalidPort
        }

        let parameters: NWParameters
        if tls {
            parameters = NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options())
        } else {
            parameters = NWParameters.tcp
        }

        connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
    }

    nonisolated func execute(
        payload: Data,
        minimumResponseBytes: Int = 1,
        maximumResponseBytes: Int = 1_024
    ) async throws -> Data {
        do {
            return try await withTimeout { [self] in
                try await self.connect()
                if !payload.isEmpty {
                    try await self.send(payload)
                }
                return try await self.receive(
                    minimumResponseBytes: minimumResponseBytes,
                    maximumResponseBytes: maximumResponseBytes
                )
            }
        } catch {
            connection.cancel()
            throw error
        }
    }

    nonisolated func exchange(
        payload: Data,
        minimumResponseBytes: Int = 1,
        maximumResponseBytes: Int = 1_024
    ) async throws -> Data {
        do {
            return try await withTimeout { [self] in
                try await self.send(payload)
                return try await self.receive(
                    minimumResponseBytes: minimumResponseBytes,
                    maximumResponseBytes: maximumResponseBytes
                )
            }
        } catch {
            connection.cancel()
            throw error
        }
    }

    nonisolated private func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.finishConnectionStart(with: .success(()), continuation: continuation)
                case .failed(let error):
                    self?.finishConnectionStart(with: .failure(error), continuation: continuation)
                case .cancelled:
                    self?.finishConnectionStart(with: .failure(ConnectionProbeError.cancelled), continuation: continuation)
                default:
                    break
                }
            }

            connection.start(queue: queue)
        }
    }

    nonisolated private func send(_ payload: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: payload, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    nonisolated private func receive(
        minimumResponseBytes: Int,
        maximumResponseBytes: Int
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(
                minimumIncompleteLength: minimumResponseBytes,
                maximumLength: maximumResponseBytes
            ) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let data, !data.isEmpty else {
                    continuation.resume(throwing: ConnectionProbeError.noResponse)
                    return
                }

                continuation.resume(returning: data)
            }
        }
    }

    nonisolated private func withTimeout<T>(
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(for: .seconds(1.2))
                throw ConnectionProbeError.timeout
            }

            guard let result = try await group.next() else {
                throw ConnectionProbeError.timeout
            }

            group.cancelAll()
            return result
        }
    }

    nonisolated private func finishConnectionStart(
        with result: Result<Void, Error>,
        continuation: CheckedContinuation<Void, Error>
    ) {
        connection.stateUpdateHandler = nil
        resumeGate.resume {
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
    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var hasResumed = false

    nonisolated func resume(_ action: () -> Void) {
        lock.lock()
        defer { lock.unlock() }

        guard !hasResumed else { return }
        hasResumed = true
        action()
    }
}
