//
//  ContentView.swift
//  Proxyy
//
//  Created by Fruvs on 3/15/26.
//

import SwiftUI
import NetworkExtension

@MainActor
struct ContentView: View {
    @StateObject private var model = ProxyDashboardModel()

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackdrop()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        topBar
                        statusPanel
                        actionRow
                        if model.fastestProxies.isEmpty == false || model.isBenchmarking {
                            fastestPanel
                        }
                        if model.locationGroups.isEmpty == false {
                            locationPanel
                        }
                        proxyPanel
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 26)
                }

                if model.isWorking {
                    BusyOverlay()
                }
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $model.settingsPresented) {
                SettingsSheet(model: model)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .alert(
                "Proxyy",
                isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { if !$0 { model.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
        .tint(.white)
    }

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                HStack(spacing: 10) {
                    Text("Proxyy")
                        .font(.system(size: 34, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)

                    Text(model.statusTitle.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(1.8)
                        .foregroundStyle(.white.opacity(0.82))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.10), in: Capsule())
                }

                Spacer(minLength: 0)

                Button {
                    model.settingsPresented = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 17, weight: .bold))
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(GlassIconButtonStyle())
            }

            if model.isBenchmarking {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(.white.opacity(0.8))
                        .controlSize(.small)

                    Text("Cataloging \(model.benchmarkProgressText)")
                        .font(.system(size: 12, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.08), in: Capsule())
            }
        }
    }

    private var statusPanel: some View {
        DarkPanel {
            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.18))
                        .frame(width: 170, height: 170)
                        .blur(radius: 8)

                    Circle()
                        .stroke(statusColor.opacity(0.22), lineWidth: 1)
                        .frame(width: 182, height: 182)

                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    statusColor.opacity(0.94),
                                    statusColor.opacity(0.76)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 140, height: 140)
                        .overlay {
                            Image(systemName: statusIcon)
                                .font(.system(size: 40, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .shadow(color: statusColor.opacity(0.42), radius: 28, y: 16)
                }

                VStack(spacing: 14) {
                    VStack(spacing: 8) {
                        Text(model.currentProxyTitle)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)

                        if model.activeProxy != nil {
                            Text(model.currentProxyDetail)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.66))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    HorizontalBadgeStrip {
                        StatusBadge(title: model.proxyCountText, subtitle: "PROXIES")
                        StatusBadge(title: model.benchmarkCountText, subtitle: "TESTED")
                        StatusBadge(title: model.profileStateText, subtitle: "PROFILE")
                        if model.isDetectingTypes {
                            StatusBadge(title: "SCAN", subtitle: "AUTO")
                        }
                    }
                }

                routeCard

                if model.isDetectingTypes == false {
                    Divider()
                        .overlay(Color.white.opacity(0.08))
                }

                HorizontalBadgeStrip {
                    StatusBadge(title: model.hasActiveTunnel ? "LIVE" : "IDLE", subtitle: "TUNNEL")
                    StatusBadge(title: model.benchmarkProgressText, subtitle: model.isBenchmarking ? "TESTING" : "BENCH")
                    if model.isDetectingTypes {
                        StatusBadge(title: "RUN", subtitle: "SCAN")
                    }
                }
            }
        }
    }

    private var actionRow: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    Task {
                        await model.connectRandomly()
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "shuffle")
                            .font(.system(size: 15, weight: .bold))

                        Text("Random")

                        Spacer(minLength: 0)

                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(PrimaryActionButtonStyle(kind: .accent))
                .disabled(!model.canConnect)

                Button {
                    Task {
                        await model.connectToFastest()
                    }
                } label: {
                    Label("Fastest", systemImage: "bolt.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryActionButtonStyle(kind: .glass))
                .disabled(!model.canConnectToFastest)
            }

            Button {
                Task {
                    await model.disconnect()
                }
            } label: {
                Label("Disconnect", systemImage: "power")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryActionButtonStyle(kind: .glass))
            .disabled(!model.hasActiveTunnel)
        }
    }

    private var fastestPanel: some View {
        DarkPanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Fastest")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Spacer()

                    Text(model.isBenchmarking ? "LIVE" : "READY")
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.82))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.10), in: Capsule())
                }

                if model.fastestProxies.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                            .tint(.white.opacity(0.82))

                        Text("Testing imported proxies")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.74))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                } else {
                    let fastestHighlights = Array(model.fastestProxies.prefix(3))

                    LazyVStack(spacing: 12) {
                        ForEach(fastestHighlights.indices, id: \.self) { index in
                            let proxy = fastestHighlights[index]
                            Button {
                                Task {
                                    await model.connect(to: proxy)
                                }
                            } label: {
                                FeaturedProxyCard(rank: index + 1, proxy: proxy)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var locationPanel: some View {
        DarkPanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Locations")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Spacer()

                    Text("\(model.locationGroups.count)")
                        .font(.system(size: 12, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.86))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.10), in: Capsule())
                }

                LazyVStack(spacing: 12) {
                    ForEach(Array(model.locationGroups.prefix(6))) { group in
                        Button {
                            Task {
                                await model.connect(to: group)
                            }
                        } label: {
                            LocationConnectRow(group: group)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var proxyPanel: some View {
        DarkPanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Proxies")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Spacer()

                    Text(model.proxyCountText)
                        .font(.system(size: 12, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.86))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.10), in: Capsule())
                }

                if model.proxies.isEmpty {
                    Button {
                        model.settingsPresented = true
                    } label: {
                        VStack(spacing: 12) {
                            Image(systemName: "circle.grid.2x2")
                                .font(.system(size: 28, weight: .medium))
                            Text("No Proxies")
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                    }
                    .buttonStyle(GlassCardButtonStyle())
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(model.proxies) { proxy in
                            Button {
                                Task {
                                    await model.connect(to: proxy)
                                }
                            } label: {
                                HomeProxyRow(
                                    proxy: proxy,
                                    isActive: model.activeProxyID == proxy.id && model.vpnStatus != .disconnected
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var routeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Active Route")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1.6)
                .foregroundStyle(.white.opacity(0.56))

            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 54, height: 54)

                    Image(systemName: model.activeProxy == nil ? "shield" : "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(model.activeProxy?.displayName ?? "Standby")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(model.activeProxy?.benchmarkStatusText ?? model.activeProxy?.subtitle ?? "No active route")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
    }

    private var statusColor: Color {
        switch model.vpnStatus {
        case .connected:
            return Color(red: 0.18, green: 0.77, blue: 0.45)
        case .connecting, .reasserting:
            return Color(red: 0.98, green: 0.71, blue: 0.24)
        case .disconnecting:
            return Color(red: 0.84, green: 0.34, blue: 0.23)
        default:
            return Color(red: 0.18, green: 0.49, blue: 0.97)
        }
    }

    private var statusIcon: String {
        switch model.vpnStatus {
        case .connected:
            return "checkmark.shield.fill"
        case .connecting, .reasserting:
            return "bolt.horizontal.fill"
        case .disconnecting:
            return "power.circle.fill"
        default:
            return "shield.lefthalf.filled"
        }
    }
}

private struct SettingsSheet: View {
    @ObservedObject var model: ProxyDashboardModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackdrop()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        settingsToolbarSpacer

                        DarkPanel {
                            HorizontalBadgeStrip {
                                StatusBadge(title: model.proxyCountText, subtitle: "PROXIES")
                                StatusBadge(title: model.profileStateText, subtitle: "PROFILE")
                                StatusBadge(title: model.benchmarkProgressText, subtitle: model.isBenchmarking ? "TESTING" : "BENCH")
                                StatusBadge(title: model.isDetectingTypes ? "RUNNING" : "IDLE", subtitle: "SCAN")
                            }
                        }

                        DarkPanel {
                            VStack(spacing: 12) {
                                SettingsActionButton(
                                    title: "Install VPN Profile",
                                    systemImage: "checkmark.shield",
                                    kind: .accent
                                ) {
                                    Task {
                                        await model.installProfile()
                                    }
                                }

                                SettingsActionButton(
                                    title: "Import Proxy List",
                                    systemImage: "tray.and.arrow.down",
                                    kind: .glass
                                ) {
                                    model.importSheetPresented = true
                                }

                                SettingsActionButton(
                                    title: "Re-Detect Types",
                                    systemImage: "scope",
                                    kind: .glass
                                ) {
                                    Task {
                                        await model.redetectProxyTypes()
                                    }
                                }

                                SettingsActionButton(
                                    title: "Refresh Benchmarks",
                                    systemImage: "gauge.with.dots.needle.50percent",
                                    kind: .glass
                                ) {
                                    Task {
                                        await model.refreshBenchmarks()
                                    }
                                }
                            }
                        }

                        DarkPanel {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("Manage")
                                    .font(.system(size: 20, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)

                                if model.proxies.isEmpty {
                                    Text("No Proxies")
                                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.white.opacity(0.74))
                                        .frame(maxWidth: .infinity, alignment: .center)
                                        .padding(.vertical, 20)
                                } else {
                                    LazyVStack(spacing: 10) {
                                        ForEach(model.proxies) { proxy in
                                            SettingsProxyRow(proxy: proxy) {
                                                model.deleteProxy(proxy)
                                            }
                                        }
                                    }

                                    Button(role: .destructive) {
                                        model.clearLibrary()
                                    } label: {
                                        Text("Clear All")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(PrimaryActionButtonStyle(kind: .danger))
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 26)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $model.importSheetPresented) {
                ProxyImportSheet(model: model)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .tint(.white)
    }

    private var settingsToolbarSpacer: some View {
        Color.clear
            .frame(height: 4)
    }
}

private struct ProxyImportSheet: View {
    @ObservedObject var model: ProxyDashboardModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.09, green: 0.12, blue: 0.22),
                        Color(red: 0.12, green: 0.20, blue: 0.33)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(spacing: 18) {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .overlay(
                            TextEditor(text: $model.importText)
                                .scrollContentBackground(.hidden)
                                .padding(14)
                                .font(.system(size: 15, weight: .medium, design: .rounded))
                                .foregroundStyle(.white)
                                .background(.clear)
                                .overlay(alignment: .topLeading) {
                                    if model.importText.isEmpty {
                                        Text("""
                                        203.0.113.10:8080:user:pass
                                        198.51.100.11:1080
                                        http://user:pass@proxy.example.com:8080
                                        socks5://user:pass@198.51.100.12:1080
                                        """)
                                        .font(.system(size: 15, weight: .medium, design: .rounded))
                                        .foregroundStyle(.white.opacity(0.34))
                                        .padding(20)
                                        .allowsHitTesting(false)
                                    }
                                }
                        )
                        .frame(minHeight: 300)

                    Spacer(minLength: 0)
                }
                .padding(20)
            }
            .navigationTitle("Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        model.importProxies()
                    }
                    .fontWeight(.bold)
                    .disabled(model.importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .tint(.white)
    }
}

private struct AppBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.07, blue: 0.18),
                    Color(red: 0.06, green: 0.17, blue: 0.32),
                    Color(red: 0.90, green: 0.38, blue: 0.19)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(Color(red: 0.20, green: 0.54, blue: 0.99).opacity(0.22))
                .frame(width: 320, height: 320)
                .blur(radius: 16)
                .offset(x: -120, y: -260)

            Circle()
                .fill(Color(red: 1.0, green: 0.58, blue: 0.18).opacity(0.24))
                .frame(width: 280, height: 280)
                .blur(radius: 10)
                .offset(x: 140, y: 260)
        }
    }
}

private struct DarkPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.08),
                                Color.black.opacity(0.20)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 24, y: 12)
    }
}

private struct StatusBadge: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 14, weight: .black, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)

            Text(subtitle)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.2)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.10), in: Capsule())
    }
}

private struct HorizontalBadgeStrip<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                content
            }
            .padding(.horizontal, 1)
        }
    }
}

private struct HomeProxyRow: View {
    let proxy: ProxyEndpoint
    let isActive: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isActive ? 0.24 : 0.14),
                                Color.white.opacity(isActive ? 0.12 : 0.06)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 54, height: 54)

                Image(systemName: proxy.hasCredentials ? "lock.shield" : "network")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white.opacity(0.92))
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(proxy.displayName)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if isActive {
                        DotBadge(color: Color(red: 0.23, green: 0.90, blue: 0.55))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(proxy.subtitle)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.64))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        TypeChip(title: proxy.typeBadge, tone: .light)

                        if proxy.hasCredentials {
                            TypeChip(title: "AUTH", tone: .warning)
                        }

                        if let benchmark = proxy.benchmark {
                            TypeChip(title: benchmark.isReachable ? "LIVE" : "DOWN", tone: benchmark.isReachable ? .accent : .warning)
                        }
                    }
                }

                if let locationText = proxy.benchmarkLocationText ?? proxy.benchmarkStatusText {
                    Text(locationText)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "arrow.up.forward")
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(.white.opacity(0.44))
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(isActive ? Color.white.opacity(0.18) : Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(isActive ? Color.white.opacity(0.28) : Color.white.opacity(0.05), lineWidth: 1)
        )
    }
}

private struct SettingsProxyRow: View {
    let proxy: ProxyEndpoint
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(proxy.displayName)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(proxy.benchmarkLocationText ?? proxy.subtitle)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.64))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let benchmarkStatusText = proxy.benchmarkStatusText {
                    Text(benchmarkStatusText)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        TypeChip(title: proxy.typeBadge, tone: .light)

                        if proxy.hasCredentials {
                            TypeChip(title: "AUTH", tone: .warning)
                        }

                        if proxy.schemeOrigin == .detected {
                            TypeChip(title: "AUTO", tone: .accent)
                        } else if proxy.needsDetection {
                            TypeChip(title: "SCAN", tone: .accent)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 10)

            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .background(Color.red.opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .foregroundStyle(.white)
        }
        .padding(16)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct FeaturedProxyCard: View {
    let rank: Int
    let proxy: ProxyEndpoint

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.20, green: 0.54, blue: 0.99).opacity(0.34),
                                Color(red: 1.0, green: 0.58, blue: 0.18).opacity(0.22)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 56, height: 56)

                Text("\(rank)")
                    .font(.system(size: 18, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(proxy.displayName)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(proxy.benchmarkLocationText ?? proxy.subtitle)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let benchmarkStatusText = proxy.benchmarkStatusText {
                    Text(benchmarkStatusText)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "bolt.horizontal.fill")
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(.white.opacity(0.52))
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct LocationConnectRow: View {
    let group: ProxyLocationGroup

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.10))
                    .frame(width: 52, height: 52)

                Image(systemName: "globe.europe.africa.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white.opacity(0.88))
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(group.title)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(group.countText)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)

                Text(group.speedText)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "arrow.up.forward")
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(.white.opacity(0.44))
        }
        .padding(16)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct SettingsActionButton: View {
    let title: String
    let systemImage: String
    let kind: PrimaryActionButtonStyle.Kind
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 22)

                Text(title)

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(PrimaryActionButtonStyle(kind: kind))
    }
}

private struct BusyOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)

                Text("Working")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.black.opacity(0.34))
            )
        }
    }
}

private struct DotBadge: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .shadow(color: color.opacity(0.5), radius: 10)
    }
}

private struct TypeChip: View {
    enum Tone {
        case light
        case warning
        case accent
    }

    let title: String
    let tone: Tone

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .tracking(1.0)
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(backgroundColor, in: Capsule())
    }

    private var backgroundColor: Color {
        switch tone {
        case .light:
            return Color.white.opacity(0.12)
        case .warning:
            return Color(red: 0.95, green: 0.50, blue: 0.23).opacity(0.62)
        case .accent:
            return Color(red: 0.17, green: 0.53, blue: 0.98).opacity(0.70)
        }
    }
}

private struct GlassIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

private struct GlassCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.84 : 1))
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}

private struct PrimaryActionButtonStyle: ButtonStyle {
    enum Kind {
        case accent
        case glass
        case danger
    }

    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 17)
            .background(background(configuration: configuration))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }

    @ViewBuilder
    private func background(configuration: Configuration) -> some View {
        switch kind {
        case .accent:
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.14, green: 0.48, blue: 0.99),
                            Color(red: 0.09, green: 0.71, blue: 0.92)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .opacity(configuration.isPressed ? 0.84 : 1)
                )
        case .glass:
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(configuration.isPressed ? 0.10 : 0.14))
        case .danger:
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.red.opacity(configuration.isPressed ? 0.38 : 0.54))
        }
    }

    private var borderColor: Color {
        switch kind {
        case .accent:
            return Color.white.opacity(0.08)
        case .glass:
            return Color.white.opacity(0.12)
        case .danger:
            return Color.red.opacity(0.22)
        }
    }
}

#Preview {
    ContentView()
}
