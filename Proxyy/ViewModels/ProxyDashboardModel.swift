//
//  ProxyDashboardModel.swift
//  Proxyy
//
//  Created by Fruvs on 3/15/26.
//

import Foundation
import Combine
import NetworkExtension

@MainActor
final class ProxyDashboardModel: ObservableObject {
    @Published private(set) var proxies: [ProxyEndpoint] = []
    @Published private(set) var vpnStatus: NEVPNStatus = .invalid
    @Published private(set) var isProfileInstalled = false
    @Published private(set) var isWorking = false
    @Published private(set) var isDetectingTypes = false
    @Published private(set) var isBenchmarking = false
    @Published private(set) var benchmarkCompletedCount = 0
    @Published private(set) var benchmarkTotalCount = 0
    @Published var importText = ""
    @Published var importSheetPresented = false
    @Published var settingsPresented = false
    @Published var errorMessage: String?
    @Published var activeProxyID: UUID?

    private let vpnService: VPNService
    private let benchmarkService: ProxyBenchmarkService
    private let defaults: UserDefaults
    private var benchmarkTask: Task<Void, Never>?
    private let benchmarkBatchSize = 20
    private var benchmarkRunID = UUID()

    init(
        vpnService: VPNService? = nil,
        defaults: UserDefaults = .standard
    ) {
        let resolvedVPNService = vpnService ?? VPNService()
        self.vpnService = resolvedVPNService
        self.benchmarkService = .shared
        self.defaults = defaults
        self.proxies = ProxyLibraryStore.loadProxies(defaults: defaults)
        self.activeProxyID = ProxyLibraryStore.loadLastConnectedProxyID(defaults: defaults)

        resolvedVPNService.onStatusChange = { [weak self] newStatus in
            self?.vpnStatus = newStatus
            if newStatus == .disconnected || newStatus == .invalid {
                self?.activeProxyID = nil
            }
        }

        Task {
            await refreshVPNState()
        }

        let requiresForcedRetest = proxies.contains { proxy in
            guard let benchmark = proxy.benchmark else {
                return false
            }

            return benchmark.isCurrent == false
        }

        if requiresForcedRetest || proxies.contains(where: { $0.benchmark == nil || $0.needsDetection }) {
            scheduleBenchmarkRefresh(forceRetest: requiresForcedRetest)
        }
    }

    var activeProxy: ProxyEndpoint? {
        guard let activeProxyID else { return nil }
        return proxies.first(where: { $0.id == activeProxyID })
    }

    var statusTitle: String {
        switch vpnStatus {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting"
        case .disconnecting:
            return "Disconnecting"
        case .reasserting:
            return "Reconnecting"
        case .disconnected:
            return "Ready"
        case .invalid:
            return isProfileInstalled ? "Needs Refresh" : "Profile Missing"
        @unknown default:
            return "Unknown"
        }
    }

    var primaryActionTitle: String {
        switch vpnStatus {
        case .connected, .connecting, .reasserting:
            return "Disconnect"
        default:
            return "Random"
        }
    }

    var currentProxyTitle: String {
        activeProxy?.displayName ?? "No Active Proxy"
    }

    var currentProxyDetail: String {
        activeProxy?.subtitle ?? " "
    }

    var proxyCountText: String {
        "\(proxies.count)"
    }

    var benchmarkCountText: String {
        "\(proxies.filter { $0.benchmark?.isReachable == true }.count)"
    }

    var profileStateText: String {
        isProfileInstalled ? "Installed" : "Missing"
    }

    var benchmarkProgressText: String {
        if isBenchmarking {
            return "\(benchmarkCompletedCount)/\(max(benchmarkTotalCount, 1))"
        }

        let testedCount = proxies.filter { $0.benchmark != nil }.count
        return "\(testedCount)/\(proxies.count)"
    }

    var canConnect: Bool {
        !proxies.isEmpty
    }

    var canConnectToFastest: Bool {
        fastestProxies.isEmpty == false
    }

    var hasActiveTunnel: Bool {
        switch vpnStatus {
        case .connected, .connecting, .reasserting:
            return true
        default:
            return false
        }
    }

    var fastestProxies: [ProxyEndpoint] {
        proxies
            .filter { $0.benchmark?.isReachable == true }
            .sorted { lhs, rhs in
                if lhs.connectionScore == rhs.connectionScore {
                    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                }

                return lhs.connectionScore > rhs.connectionScore
            }
    }

    var locationGroups: [ProxyLocationGroup] {
        let grouped = Dictionary(grouping: fastestProxies) { proxy in
            proxy.benchmark?.location?.groupKey ?? "unknown"
        }

        return grouped.values
            .compactMap { group in
                guard
                    let bestProxy = group.max(by: { $0.connectionScore < $1.connectionScore }),
                    let location = bestProxy.benchmark?.location
                else {
                    return nil
                }

                return ProxyLocationGroup(
                    id: location.groupKey,
                    location: location,
                    proxies: group.sorted { $0.connectionScore > $1.connectionScore }
                )
            }
            .sorted { lhs, rhs in
                if lhs.bestProxy.connectionScore == rhs.bestProxy.connectionScore {
                    return lhs.location.displayName.localizedCaseInsensitiveCompare(rhs.location.displayName) == .orderedAscending
                }

                return lhs.bestProxy.connectionScore > rhs.bestProxy.connectionScore
            }
    }

    func refreshVPNState() async {
        do {
            let snapshot = try await vpnService.refreshSnapshot()
            vpnStatus = snapshot.status
            isProfileInstalled = snapshot.isProfileInstalled
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func installProfile() async {
        await runAction { [self] in
            let snapshot = try await self.vpnService.installProfile()
            self.vpnStatus = snapshot.status
            self.isProfileInstalled = snapshot.isProfileInstalled
        }
    }

    func togglePrimaryAction() async {
        switch vpnStatus {
        case .connected, .connecting, .reasserting:
            await disconnect()
        default:
            await connectRandomly()
        }
    }

    func connectRandomly() async {
        guard let proxy = proxies.randomElement() else {
            errorMessage = "Add at least one proxy in Settings before connecting."
            return
        }

        await connect(to: proxy)
    }

    func connectToFastest() async {
        guard let proxy = fastestProxies.first else {
            errorMessage = "Benchmark your proxies first to connect to the fastest route."
            return
        }

        await connect(to: proxy)
    }

    func connect(to locationGroup: ProxyLocationGroup) async {
        await connect(to: locationGroup.bestProxy)
    }

    func connect(to proxy: ProxyEndpoint) async {
        await runAction { [self] in
            let resolvedProxy = try await self.prepareProxy(proxy)
            let snapshot = try await self.vpnService.connect(using: resolvedProxy)
            self.vpnStatus = snapshot.status
            self.isProfileInstalled = snapshot.isProfileInstalled
            self.activeProxyID = resolvedProxy.id
            ProxyLibraryStore.saveLastConnectedProxyID(resolvedProxy.id, defaults: self.defaults)
        }
    }

    func disconnect() async {
        await runAction { [self] in
            let snapshot = try await self.vpnService.disconnect()
            self.vpnStatus = snapshot.status
            self.isProfileInstalled = snapshot.isProfileInstalled
            self.activeProxyID = nil
            ProxyLibraryStore.saveLastConnectedProxyID(nil, defaults: self.defaults)
        }
    }

    func importProxies() {
        let result = ProxyListParser.parse(importText)
        guard !result.proxies.isEmpty else {
            errorMessage = result.issues.first?.reason ?? "No valid proxies were found in the pasted list."
            return
        }

        let merged = merge(result.proxies, into: proxies)
        proxies = merged
        ProxyLibraryStore.saveProxies(merged, defaults: defaults)
        importText = ""
        importSheetPresented = false
        scheduleBenchmarkRefresh(forceRetest: true)
    }

    func deleteProxy(_ proxy: ProxyEndpoint) {
        proxies.removeAll { $0.id == proxy.id }
        ProxyLibraryStore.saveProxies(proxies, defaults: defaults)

        if activeProxyID == proxy.id {
            activeProxyID = nil
            ProxyLibraryStore.saveLastConnectedProxyID(nil, defaults: defaults)
        }
    }

    func clearLibrary() {
        benchmarkTask?.cancel()
        proxies = []
        activeProxyID = nil
        benchmarkCompletedCount = 0
        benchmarkTotalCount = 0
        isBenchmarking = false
        ProxyLibraryStore.saveProxies([], defaults: defaults)
        ProxyLibraryStore.saveLastConnectedProxyID(nil, defaults: defaults)
    }

    func redetectProxyTypes() async {
        guard !proxies.isEmpty else {
            return
        }

        for index in proxies.indices where proxies[index].schemeOrigin != .explicit {
            proxies[index].scheme = .unknown
            proxies[index].schemeOrigin = .unknown
        }

        ProxyLibraryStore.saveProxies(proxies, defaults: defaults)
        await detectPendingProxyTypes()
    }

    func refreshBenchmarks() async {
        benchmarkTask?.cancel()
        scheduleBenchmarkRefresh(forceRetest: true)
    }

    private func merge(_ newProxies: [ProxyEndpoint], into current: [ProxyEndpoint]) -> [ProxyEndpoint] {
        var merged = current
        var indexByKey: [String: Int] = [:]

        for (index, proxy) in merged.enumerated() {
            indexByKey[proxy.endpointKey] = index
        }

        for proxy in newProxies {
            if let index = indexByKey[proxy.endpointKey] {
                merged[index] = merged[index].mergingMetadata(with: proxy)
            } else {
                indexByKey[proxy.endpointKey] = merged.count
                merged.append(proxy)
            }
        }

        return merged
    }

    private func prepareProxy(_ proxy: ProxyEndpoint) async throws -> ProxyEndpoint {
        guard proxy.needsDetection else {
            return proxy
        }

        isDetectingTypes = true
        defer {
            isDetectingTypes = false
        }

        let detectedScheme = await ProxyTypeDetector.detect(for: proxy)
        guard detectedScheme.isResolved else {
            throw ProxyResolutionError.undetectedType(proxy.addressText)
        }

        let resolvedProxy = proxy.applyingDetectedScheme(detectedScheme)
        replaceProxy(resolvedProxy)
        return resolvedProxy
    }

    private func detectPendingProxyTypes() async {
        guard !isDetectingTypes else { return }

        let pendingIDs = Set(
            proxies
                .filter(\.needsDetection)
                .map(\.id)
        )

        guard !pendingIDs.isEmpty else { return }

        isDetectingTypes = true
        defer {
            isDetectingTypes = false
        }

        var updatedProxies = proxies
        var changed = false

        for index in updatedProxies.indices where pendingIDs.contains(updatedProxies[index].id) {
            let detectedScheme = await ProxyTypeDetector.detect(for: updatedProxies[index])
            guard detectedScheme.isResolved else {
                continue
            }

            updatedProxies[index] = updatedProxies[index].applyingDetectedScheme(detectedScheme)
            changed = true
        }

        guard changed else { return }

        proxies = updatedProxies
        ProxyLibraryStore.saveProxies(updatedProxies, defaults: defaults)
    }

    private func replaceProxy(_ proxy: ProxyEndpoint, persist: Bool = true) {
        guard let index = proxies.firstIndex(where: { $0.id == proxy.id }) else {
            return
        }

        proxies[index] = proxy
        if persist {
            ProxyLibraryStore.saveProxies(proxies, defaults: defaults)
        }
    }

    private func scheduleBenchmarkRefresh(forceRetest: Bool) {
        benchmarkTask?.cancel()
        let seedProxies = proxies
        let benchmarkService = benchmarkService
        let batchSize = benchmarkBatchSize
        let runID = UUID()
        benchmarkRunID = runID

        benchmarkTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.beginBenchmarking(total: seedProxies.count, runID: runID)

            var progressCount = 0
            var latestProxies = seedProxies
            var dirtyIDs: Set<UUID> = []

            defer {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.benchmarkRunID == runID else { return }
                    self.isBenchmarking = false
                    ProxyLibraryStore.saveProxies(self.proxies, defaults: self.defaults)
                }
            }

            for index in seedProxies.indices {
                if Task.isCancelled {
                    break
                }

                let originalProxy = seedProxies[index]
                if forceRetest == false, originalProxy.benchmark != nil, originalProxy.needsDetection == false {
                    progressCount += 1
                    if progressCount.isMultiple(of: batchSize) {
                        await self.publishBenchmarkProgress(completed: progressCount, runID: runID)
                    }
                    continue
                }

                let update = await Self.buildBenchmarkUpdate(
                    for: originalProxy,
                    benchmarkService: benchmarkService
                )

                latestProxies[index] = update.proxy
                dirtyIDs.insert(update.proxy.id)
                progressCount += 1

                if dirtyIDs.count >= batchSize || progressCount == seedProxies.count {
                    await self.applyBenchmarkBatch(
                        from: latestProxies,
                        updatedIDs: dirtyIDs,
                        completed: progressCount,
                        runID: runID
                    )
                    dirtyIDs.removeAll(keepingCapacity: true)
                } else if progressCount.isMultiple(of: batchSize) {
                    await self.publishBenchmarkProgress(completed: progressCount, runID: runID)
                }
            }
        }
    }

    private func beginBenchmarking(total: Int, runID: UUID) {
        guard benchmarkRunID == runID else { return }

        guard total > 0 else {
            isBenchmarking = false
            benchmarkCompletedCount = 0
            benchmarkTotalCount = 0
            return
        }

        isBenchmarking = true
        benchmarkCompletedCount = 0
        benchmarkTotalCount = total
    }

    private func publishBenchmarkProgress(completed: Int, runID: UUID) {
        guard benchmarkRunID == runID else { return }
        benchmarkCompletedCount = completed
    }

    private func applyBenchmarkBatch(
        from snapshot: [ProxyEndpoint],
        updatedIDs: Set<UUID>,
        completed: Int,
        runID: UUID
    ) {
        guard benchmarkRunID == runID else { return }

        guard updatedIDs.isEmpty == false else {
            benchmarkCompletedCount = completed
            return
        }

        let updatesByID = Dictionary(
            uniqueKeysWithValues: snapshot
                .filter { updatedIDs.contains($0.id) }
                .map { ($0.id, $0) }
        )

        for index in proxies.indices {
            if let updatedProxy = updatesByID[proxies[index].id] {
                proxies[index] = updatedProxy
            }
        }

        benchmarkCompletedCount = completed
        ProxyLibraryStore.saveProxies(proxies, defaults: defaults)
    }

    private static func buildBenchmarkUpdate(
        for proxy: ProxyEndpoint,
        benchmarkService: ProxyBenchmarkService
    ) async -> BenchmarkUpdate {
        let resolvedProxy: ProxyEndpoint

        if proxy.needsDetection {
            let detectedScheme = await ProxyTypeDetector.detect(for: proxy)
            guard detectedScheme.isResolved else {
                let benchmark = ProxyBenchmark(
                    schemaVersion: ProxyBenchmark.currentSchemaVersion,
                    testedAt: Date(),
                    latencyMilliseconds: nil,
                    downloadMegabitsPerSecond: nil,
                    exitIPAddress: nil,
                    location: nil,
                    isReachable: false,
                    failureReason: ProxyResolutionError.undetectedType(proxy.addressText).localizedDescription
                )
                return BenchmarkUpdate(proxy: proxy.applyingBenchmark(benchmark))
            }

            resolvedProxy = proxy.applyingDetectedScheme(detectedScheme)
        } else {
            resolvedProxy = proxy
        }

        let benchmark = await benchmarkService.benchmark(resolvedProxy)
        return BenchmarkUpdate(proxy: resolvedProxy.applyingBenchmark(benchmark))
    }

    private func runAction(_ work: @escaping () async throws -> Void) async {
        guard !isWorking else { return }

        isWorking = true
        errorMessage = nil

        defer {
            isWorking = false
        }

        do {
            try await work()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct BenchmarkUpdate: Sendable {
    let proxy: ProxyEndpoint
}

struct ProxyLocationGroup: Identifiable, Hashable {
    let id: String
    let location: ProxyLocation
    let proxies: [ProxyEndpoint]

    var bestProxy: ProxyEndpoint {
        proxies[0]
    }

    var title: String {
        location.displayName
    }

    var countText: String {
        "\(proxies.count) proxies"
    }

    var speedText: String {
        bestProxy.benchmarkStatusText ?? "Ready"
    }
}

private enum ProxyResolutionError: LocalizedError {
    case undetectedType(String)

    var errorDescription: String? {
        switch self {
        case .undetectedType(let address):
            return "Proxy type could not be detected for \(address)."
        }
    }
}
