# Proxyy

Proxyy is an iOS proxy manager that imports proxy lists, detects proxy types, benchmarks endpoints, ranks the usable routes, and connects traffic through a NetworkExtension packet-tunnel profile.

## What It Does

- Imports proxy lists from pasted text.
- Supports explicit proxy URLs such as `http://user:pass@host:port`, `https://host:port`, `socks4://host:port`, and `socks5://host:port`.
- Supports raw proxy rows in `host:port` and `host:port:user:pass` format.
- Deduplicates imported endpoints while preserving stronger metadata.
- Detects unknown proxy types by probing HTTP, HTTPS, SOCKS5, and SOCKS4 behavior.
- Benchmarks reachable proxies for latency, exit IP, approximate download speed, and location.
- Builds ranked proxy/location groups for quick connection selection.
- Installs and controls a `NETunnelProviderManager` profile backed by a packet-tunnel extension.

## Architecture

The app is split into a SwiftUI host app and a NetworkExtension tunnel target.

- `Proxyy/ContentView.swift` renders the dashboard, import flow, settings, route list, and connection controls.
- `Proxyy/ViewModels/ProxyDashboardModel.swift` coordinates import, detection, benchmarking, persistence, and VPN actions.
- `Proxyy/Services/VPNService.swift` owns the `NETunnelProviderManager` lifecycle and tunnel start/stop behavior.
- `Proxyy/Services/ProxyListParser.swift` parses pasted proxy lists.
- `Proxyy/Services/ProxyTypeDetector.swift` probes unresolved proxies.
- `Proxyy/Services/ProxyBenchmarkService.swift` measures reachability, latency, speed, exit IP, and location.
- `Proxyy/Services/ProxyLibraryStore.swift` persists proxy metadata and stores credentials in Keychain.
- `ProxyyTunnel/PacketTunnelProvider.swift` runs the local loopback proxy bridge inside the packet-tunnel extension.

## Tunnel Flow

When a proxy is selected, the app saves a NetworkExtension profile for the Proxyy packet tunnel. The tunnel extension starts a local loopback HTTP/HTTPS proxy listener, applies proxy settings that point system traffic at that listener, and forwards requests to the selected upstream HTTP, HTTPS, SOCKS4, or SOCKS5 proxy.

Proxy credentials are not written into the persisted proxy JSON or copied into the tunnel payload. The app stores credentials in a shared Keychain access group and passes the tunnel only an opaque credential reference.

## Security Notes

- HTTPS proxy connections use normal system TLS verification.
- Proxy usernames and passwords are stored in Keychain rather than Application Support JSON.
- The app filters saved NetworkExtension managers to the Proxyy profile before modifying or connecting a tunnel.
- Switching proxies waits for an active tunnel to stop before starting the next one.

## Requirements

- Xcode 17 or newer.
- iOS 16.0 or newer.
- A development team with the `packet-tunnel-provider` NetworkExtension entitlement.
- A shared Keychain access group for the app and tunnel extension.

## Build

```sh
xcodebuild build \
  -project Proxyy.xcodeproj \
  -scheme Proxyy \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'
```

## Tests

```sh
xcodebuild test \
  -project Proxyy.xcodeproj \
  -scheme Proxyy \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'
```

The current unit tests cover parser behavior and credential redaction from encoded proxy data and tunnel payloads.
Writen by Codex and Claude
