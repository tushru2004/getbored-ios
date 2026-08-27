import Foundation

extension IOSDecisionCore {
    // MARK: - Protocol Inspection

    /// Call flow:
    ///
    ///   TLS bytes → verify ClientHello → skip fixed fields → scan extensions ×N
    ///       ├── server-name extension → decode hostname
    ///       └── missing/truncated data → nil
    public static func extractSNI(from data: Data) -> String? {
        let bytes = Array(data.prefix(512))
        let isTLSClientHello = bytes.count > 5 && bytes[0] == 0x16 && bytes[5] == 0x01
        guard isTLSClientHello else { return nil }
        var cursor = 43
        guard cursor < bytes.count else { return nil }
        let sessionIDLength = Int(bytes[cursor])
        cursor += 1 + sessionIDLength
        guard cursor + 2 <= bytes.count else { return nil }
        let cipherSuitesLength = Int(bytes[cursor]) * 256 + Int(bytes[cursor + 1])
        cursor += 2 + cipherSuitesLength
        guard cursor < bytes.count else { return nil }
        let compressionMethodsLength = Int(bytes[cursor])
        cursor += 1 + compressionMethodsLength
        guard cursor + 2 <= bytes.count else { return nil }
        let extensionsLength = Int(bytes[cursor]) * 256 + Int(bytes[cursor + 1])
        cursor += 2
        let extensionsEnd = min(bytes.count, cursor + extensionsLength)
        while cursor + 4 <= extensionsEnd {
            let extensionType = Int(bytes[cursor]) * 256 + Int(bytes[cursor + 1])
            let extensionLength = Int(bytes[cursor + 2]) * 256 + Int(bytes[cursor + 3])
            cursor += 4
            if extensionType == 0 {
                guard cursor + 5 <= extensionsEnd else { return nil }
                let serverNameLength = Int(bytes[cursor + 3]) * 256 + Int(bytes[cursor + 4])
                let serverNameStart = cursor + 5
                guard serverNameStart + serverNameLength <= extensionsEnd else { return nil }
                return String(
                    decoding: bytes[serverNameStart..<(serverNameStart + serverNameLength)],
                    as: UTF8.self)
            }
            cursor += extensionLength
        }
        return nil
    }

    public static func extractHTTPHost(from data: Data) -> String? {
        guard let text = String(data: data.prefix(512), encoding: .ascii), isHTTPRequest(text)
        else { return nil }
        return text.split(whereSeparator: \.isNewline).first { $0.lowercased().hasPrefix("host:") }
            .flatMap {
                String($0.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines).split(
                    separator: ":", maxSplits: 1
                ).first.map(String.init)
            }
    }

    public static func extractHTTPFullURL(from data: Data) -> String? {
        guard let text = String(data: data.prefix(512), encoding: .ascii), isHTTPRequest(text),
            let request = text.split(whereSeparator: \.isNewline).first
        else { return nil }
        let parts = request.split(separator: " ")
        guard parts.count >= 2, let host = extractHTTPHost(from: data) else { return nil }
        return host + String(parts[1])
    }

    // MARK: - Blocked Host Resolution

    /// Call flow:
    ///
    ///   URL host → socket endpoint → source-app fallback → unknown marker
    ///       │              │                  │
    ///       └── first resolvable hostname wins ┘
    public static func resolveBlockedHost(
        rawURLHost: String?, rawEndpoint: String?, sourceApp: String?
    ) -> BlockedHostResolution {
        let normalizedURLHost = normalizedBlockedHost(rawURLHost)
        let normalizedEndpoint = normalizedBlockedHost(rawEndpoint)
        if let host = normalizedURLHost, isResolvableHost(host) {
            return BlockedHostResolution(
                displayDomain: host, rawEndpoint: normalizedEndpoint, resolutionSource: "url-host",
                isResolvableHostname: true)
        }
        if let host = normalizedEndpoint, isResolvableHost(host) {
            return BlockedHostResolution(
                displayDomain: host, rawEndpoint: normalizedEndpoint,
                resolutionSource: "socket-endpoint", isResolvableHostname: true)
        }
        let sourceAppFallback = nonBlank(sourceApp).map { "app:\($0)" }
        let displayDomain =
            sourceAppFallback ?? normalizedURLHost ?? normalizedEndpoint ?? "unknown-blocked-flow"
        let resolutionSource = sourceApp == nil ? "unresolved" : "source-app-fallback"
        return BlockedHostResolution(
            displayDomain: displayDomain, rawEndpoint: normalizedEndpoint ?? normalizedURLHost,
            resolutionSource: resolutionSource, isResolvableHostname: false)
    }

    private static func isHTTPRequest(_ value: String) -> Bool {
        ["GET ", "POST ", "PUT ", "DELETE ", "HEAD ", "CONNECT "].contains { value.hasPrefix($0) }
    }
    private static func normalizedBlockedHost(_ raw: String?) -> String? {
        guard let host = normalizeHost(raw), !host.isEmpty, host != "unknown" else { return nil }
        return host
    }
    private static func isResolvableHost(_ host: String) -> Bool {
        !host.hasPrefix("app:") && !isIP(host)
    }
    private static func isIP(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[] ."))
            .lowercased()
        let v4 = normalized.split(separator: ".")
        if v4.count == 4 && v4.allSatisfy({ Int($0).map { 0...255 ~= $0 } ?? false }) {
            return true
        }
        let v6 = normalized.split(separator: ":", omittingEmptySubsequences: false)
        return v6.count > 1
            && v6.allSatisfy { $0.isEmpty || ($0.count <= 4 && $0.allSatisfy(\.isHexDigit)) }
    }
}
