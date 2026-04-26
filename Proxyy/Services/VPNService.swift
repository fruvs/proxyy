//
//  VPNService.swift
//  Proxyy
//
//  Created by Fruvs on 3/15/26.
//

import Foundation
@preconcurrency import NetworkExtension

private enum VPNRuntimeProxy {
    static let loopbackHost = "127.0.0.1"
    static let loopbackPort = 8_191
}

struct VPNSnapshot: Sendable {
    let status: NEVPNStatus
    let isProfileInstalled: Bool
}

enum VPNServiceError: LocalizedError {
    case unsupportedConnectionType
    case disconnectTimedOut

    var errorDescription: String? {
        switch self {
        case .unsupportedConnectionType:
            return "The saved VPN profile could not be opened as a packet tunnel session."
        case .disconnectTimedOut:
            return "The current VPN tunnel did not disconnect in time."
        }
    }
}

@MainActor
final class VPNService {
    nonisolated static let appDescription = "Proxyy"
    nonisolated static let providerBundleIdentifier = "fruvs.Proxyy.ProxyyTunnel"

    var onStatusChange: ((NEVPNStatus) -> Void)?

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
    }

    func refreshSnapshot() async throws -> VPNSnapshot {
        let manager = try await loadOrCreateManager()
        attachStatusObserver(to: manager)
        return VPNSnapshot(
            status: manager.connection.status,
            isProfileInstalled: manager.protocolConfiguration != nil
        )
    }

    func installProfile() async throws -> VPNSnapshot {
        let manager = try await loadOrCreateManager()
        configure(manager, proxy: nil)
        let reloadedManager = try await saveAndReload(manager)
        attachStatusObserver(to: reloadedManager)
        return VPNSnapshot(status: reloadedManager.connection.status, isProfileInstalled: true)
    }

    func connect(using proxy: ProxyEndpoint) async throws -> VPNSnapshot {
        var manager = try await loadOrCreateManager()
        configure(manager, proxy: proxy)
        manager = try await saveAndReload(manager)
        attachStatusObserver(to: manager)

        guard let session = manager.connection as? NETunnelProviderSession else {
            throw VPNServiceError.unsupportedConnectionType
        }

        try await stopActiveTunnelIfNeeded(session)
        try session.startTunnel(options: proxy.profilePayload.compactMapValues { $0 as? NSObject })

        return VPNSnapshot(status: manager.connection.status, isProfileInstalled: true)
    }

    func disconnect() async throws -> VPNSnapshot {
        let manager = try await loadOrCreateManager()
        attachStatusObserver(to: manager)
        manager.connection.stopVPNTunnel()
        return VPNSnapshot(status: manager.connection.status, isProfileInstalled: manager.protocolConfiguration != nil)
    }

    private func loadOrCreateManager() async throws -> NETunnelProviderManager {
        if let manager {
            return manager
        }

        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let manager = managers.first(where: Self.isProxyyManager) ?? NETunnelProviderManager()
        self.manager = manager
        return manager
    }

    private func configure(_ manager: NETunnelProviderManager, proxy: ProxyEndpoint?) {
        let tunnelProtocol = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        tunnelProtocol.providerBundleIdentifier = Self.providerBundleIdentifier
        tunnelProtocol.serverAddress = proxy?.displayName ?? "Proxy routing"
        tunnelProtocol.providerConfiguration = proxy?.profilePayload
        tunnelProtocol.proxySettings = proxy.map { _ in
            makeLoopbackProxySettings()
        }

        manager.localizedDescription = Self.appDescription
        manager.protocolConfiguration = tunnelProtocol
        manager.isEnabled = true
    }

    private func saveAndReload(_ manager: NETunnelProviderManager) async throws -> NETunnelProviderManager {
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        self.manager = manager
        return manager
    }

    private func attachStatusObserver(to manager: NETunnelProviderManager) {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }

        let connection = manager.connection

        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: connection,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onStatusChange?(connection.status)
            }
        }
    }

    private func stopActiveTunnelIfNeeded(_ session: NETunnelProviderSession) async throws {
        guard Self.isActiveStatus(session.status) else {
            return
        }

        session.stopVPNTunnel()
        try await waitForStoppedTunnel(session)
    }

    private func waitForStoppedTunnel(_ connection: NEVPNConnection) async throws {
        guard !Self.isStoppedStatus(connection.status) else {
            return
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = VPNContinuationGate()
            var observer: NSObjectProtocol?

            let finish: (Result<Void, Error>) -> Void = { result in
                gate.resume {
                    if let observer {
                        NotificationCenter.default.removeObserver(observer)
                    }

                    switch result {
                    case .success:
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }

            observer = NotificationCenter.default.addObserver(
                forName: .NEVPNStatusDidChange,
                object: connection,
                queue: .main
            ) { _ in
                if Self.isStoppedStatus(connection.status) {
                    finish(.success(()))
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                finish(.failure(VPNServiceError.disconnectTimedOut))
            }
        }
    }

    nonisolated private static func isProxyyManager(_ manager: NETunnelProviderManager) -> Bool {
        if manager.localizedDescription == appDescription {
            return true
        }

        let tunnelProtocol = manager.protocolConfiguration as? NETunnelProviderProtocol
        return tunnelProtocol?.providerBundleIdentifier == providerBundleIdentifier
    }

    nonisolated private static func isActiveStatus(_ status: NEVPNStatus) -> Bool {
        switch status {
        case .connected, .connecting, .reasserting:
            return true
        default:
            return false
        }
    }

    nonisolated private static func isStoppedStatus(_ status: NEVPNStatus) -> Bool {
        switch status {
        case .disconnected, .invalid:
            return true
        default:
            return false
        }
    }

    private func makeLoopbackProxySettings() -> NEProxySettings {
        let proxySettings = NEProxySettings()
        let proxyServer = NEProxyServer(
            address: VPNRuntimeProxy.loopbackHost,
            port: VPNRuntimeProxy.loopbackPort
        )

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

private final class VPNContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false

    func resume(_ action: () -> Void) {
        lock.lock()
        defer { lock.unlock() }

        guard !hasResumed else { return }
        hasResumed = true
        action()
    }
}
