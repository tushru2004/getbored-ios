import Foundation
import GetBoredCore

extension IOSDecisionCore {
    // MARK: - Safari App Proxy Decision Types

    public enum ParentChildDecisionKind: Equatable {
        case noActiveContext
        case staleActiveContext
        case matchActiveParent
        case matchActiveChild
        case noActiveMatch
    }
    public struct ParentChildDecision {
        public let kind: ParentChildDecisionKind
        public let host: String
        public let endpoint: String
        public let activeParent: String
        public let ageSeconds: TimeInterval
        public let childCount: Int
        public let event: String
        public let observationDecision: String
        public let shouldAllow: Bool
    }
    public struct SafariRelayDecision {
        public let shouldRelay: Bool
        public let host: String
        public let primaryEvent: String
        public let outcomeEvent: String
        public let parentChildKind: ParentChildDecisionKind
        public let activeParent: String
        public let observationDecision: String
        public let shouldSaveFlowObservation: Bool
        public let shouldRefreshActiveContext: Bool
        public let refreshEvent: String
    }

    // MARK: - Safari App Proxy Decisions

    /// Call flow:
    ///
    ///   endpoint
    ///       ├── unsupported endpoint → do not relay
    ///       ▼
    ///   classify host without parent context
    ///       ├── directly allowed → relay; optionally refresh active context
    ///       └── otherwise → compare active Safari parent and children
    ///               ├── child match → relay + save observation
    ///               └── other result → relay + record diagnostic outcome
    public static func safariRelayDecision(
        endpoint: String, using rules: LoadedFilterRules, systemAllowedSuffixes: [String],
        activeParent: String?,
        activeChildren: [String], activeContextAge: TimeInterval, activeContextMaxAge: TimeInterval,
        activeContextRefreshMinAge: TimeInterval
    ) -> SafariRelayDecision {
        guard let host = endpointHost(endpoint) else {
            return SafariRelayDecision(
                shouldRelay: false, host: "",
                primaryEvent: "BLOCK_UNSUPPORTED_ENDPOINT endpoint=\(endpoint)", outcomeEvent: "",
                parentChildKind: .noActiveContext, activeParent: "",
                observationDecision: "unsupportedEndpoint", shouldSaveFlowObservation: false,
                shouldRefreshActiveContext: false, refreshEvent: "")
        }
        if !classifyHost(
            host, using: rules, systemAllowedSuffixes: systemAllowedSuffixes,
            allowedSafariParent: nil
        ).blocked {
            let parent = activeParent ?? ""
            let matchingRule = rules.siteRules.map(\.url).compactMap(normalizeHost).first {
                hostMatchesDomain(parent, domain: $0)
            }
            let isOldEnoughToRefresh = activeContextAge > activeContextRefreshMinAge
            let shouldRefreshActiveContext: Bool
            if let matchingRule {
                shouldRefreshActiveContext =
                    isOldEnoughToRefresh && hostMatchesDomain(host, domain: matchingRule)
            } else {
                shouldRefreshActiveContext = false
            }
            let refreshEvent: String
            if shouldRefreshActiveContext, let matchingRule {
                refreshEvent =
                    "APP_PROXY_REFRESH_ACTIVE_CONTEXT rule=\(matchingRule) age=\(rounded(activeContextAge)) host=\(host) parent=\(parent)"
            } else {
                refreshEvent = ""
            }
            return SafariRelayDecision(
                shouldRelay: true, host: host,
                primaryEvent: "APP_PROXY_ALLOW_DIRECT host=\(host) endpoint=\(endpoint)",
                outcomeEvent: "", parentChildKind: .matchActiveParent, activeParent: parent,
                observationDecision: "directAllow", shouldSaveFlowObservation: false,
                shouldRefreshActiveContext: shouldRefreshActiveContext, refreshEvent: refreshEvent)
        }
        let result = parentChildDecision(
            host: host, endpoint: endpoint, parent: activeParent, children: activeChildren,
            age: activeContextAge, maxAge: activeContextMaxAge)
        let outcome: String
        switch result.kind {
        case .matchActiveParent:
            outcome = "APP_PROXY_ALLOW_ACTIVE_PARENT host=\(host) endpoint=\(endpoint)"
        case .matchActiveChild:
            outcome =
                "APP_PROXY_ALLOW_ACTIVE_CHILD host=\(host) parent=\(result.activeParent) endpoint=\(endpoint)"
        default:
            outcome =
                "APP_PROXY_ALLOW_UNCLASSIFIED host=\(host) decision=\(result.observationDecision) endpoint=\(endpoint)"
        }
        return SafariRelayDecision(
            shouldRelay: true, host: host, primaryEvent: result.event, outcomeEvent: outcome,
            parentChildKind: result.kind, activeParent: result.activeParent,
            observationDecision: result.observationDecision,
            shouldSaveFlowObservation: result.kind == .matchActiveChild,
            shouldRefreshActiveContext: false, refreshEvent: "")
    }

    /// Call flow:
    ///
    ///   active context
    ///       ├── missing → no active context
    ///       ├── expired → stale context
    ///       ├── host matches parent → allow parent
    ///       ├── host matches child pattern → allow child
    ///       └── otherwise → no active match
    private static func parentChildDecision(
        host: String, endpoint: String, parent: String?, children: [String], age: TimeInterval,
        maxAge: TimeInterval
    ) -> ParentChildDecision {
        guard let parent = normalizeHost(parent), !parent.isEmpty else {
            return ParentChildDecision(
                kind: .noActiveContext, host: host, endpoint: endpoint, activeParent: "",
                ageSeconds: 0, childCount: 0,
                event: "BLOCK_NO_CONTEXT host=\(host) endpoint=\(endpoint)",
                observationDecision: "noActiveContext", shouldAllow: false)
        }
        let count = children.count
        if age > maxAge {
            return ParentChildDecision(
                kind: .staleActiveContext, host: host, endpoint: endpoint, activeParent: parent,
                ageSeconds: age, childCount: count,
                event: "BLOCK_STALE host=\(host) activeParent=\(parent) age=\(rounded(age))",
                observationDecision: "staleActiveContext", shouldAllow: false)
        }
        if hostMatchesDomain(host, domain: parent) {
            return ParentChildDecision(
                kind: .matchActiveParent, host: host, endpoint: endpoint, activeParent: parent,
                ageSeconds: age, childCount: count,
                event: "ALLOW_PARENT host=\(host) parent=\(parent) age=\(rounded(age))",
                observationDecision: "matchActiveParent", shouldAllow: true)
        }
        if children.contains(where: { hostMatchesChildPattern(host, childPattern: $0) }) {
            return ParentChildDecision(
                kind: .matchActiveChild, host: host, endpoint: endpoint, activeParent: parent,
                ageSeconds: age, childCount: count,
                event: "ALLOW_CHILD host=\(host) parent=\(parent) age=\(rounded(age))",
                observationDecision: "matchActiveChild", shouldAllow: true)
        }
        return ParentChildDecision(
            kind: .noActiveMatch, host: host, endpoint: endpoint, activeParent: parent,
            ageSeconds: age, childCount: count,
            event:
                "BLOCK_NO_MATCH host=\(host) activeParent=\(parent) childCount=\(count) age=\(rounded(age))",
            observationDecision: "noActiveMatch", shouldAllow: false)
    }
    private static func endpointHost(_ endpoint: String) -> String? {
        let token = endpoint.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        guard let colon = token.firstIndex(of: ":") else { return nil }
        return normalizeHost(String(token[..<colon])).flatMap { $0.isEmpty ? nil : $0 }
    }
    private static func rounded(_ value: TimeInterval) -> String {
        String((value * 10).rounded() / 10)
    }
}
