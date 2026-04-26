//
//  ProxyTunnelConfiguration.swift
//  ProxyyTunnel
//
//  Created by Fruvs on 3/15/26.
//

import Foundation

enum ProxyScheme: String {
    case unknown
    case http
    case https
    case socks
    case socks4
    case socks5
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
