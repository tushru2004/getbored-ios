import Foundation

struct SafariParentChildPolicy {
    struct ActivePageContext {
        let parent: String
        let children: Set<String>
        let receivedAt: Date
    }

    enum Decision {
        case noActiveContext(host: String, endpoint: String)
        case staleActiveContext(host: String, activeParent: String, age: TimeInterval)
        case matchActiveParent(host: String, parent: String, age: TimeInterval)
        case matchActiveChild(host: String, parent: String, age: TimeInterval)
        case noActiveMatch(host: String, activeParent: String, childCount: Int, age: TimeInterval)

        var event: String {
            switch self {
            case .noActiveContext(let host, let endpoint):
                return "JOIN_NO_ACTIVE_CONTEXT host=\(host) endpoint=\(endpoint)"
            case .staleActiveContext(let host, let activeParent, let age):
                return "JOIN_STALE_ACTIVE_CONTEXT host=\(host) activeParent=\(activeParent) age=\(Self.format(age))"
            case .matchActiveParent(let host, let parent, let age):
                return "JOIN_MATCH_ACTIVE_PARENT host=\(host) parent=\(parent) age=\(Self.format(age))"
            case .matchActiveChild(let host, let parent, let age):
                return "JOIN_MATCH_ACTIVE_CHILD host=\(host) parent=\(parent) age=\(Self.format(age))"
            case .noActiveMatch(let host, let activeParent, let childCount, let age):
                return "JOIN_NO_ACTIVE_MATCH host=\(host) activeParent=\(activeParent) childCount=\(childCount) age=\(Self.format(age))"
            }
        }

        var observationDecision: String {
            switch self {
            case .matchActiveParent:
                return "matchActiveParent"
            case .matchActiveChild:
                return "matchActiveChild"
            case .noActiveContext:
                return "noActiveContext"
            case .staleActiveContext:
                return "staleActiveContext"
            case .noActiveMatch:
                return "noActiveMatch"
            }
        }

        private static func format(_ age: TimeInterval) -> String {
            String(format: "%.1f", age)
        }
    }

    let activeContextMaxAge: TimeInterval

    func decide(
        requestHost host: String,
        endpoint: String,
        activeContext: ActivePageContext?,
        now: Date = Date()
    ) -> Decision {
        guard let activeContext else {
            return .noActiveContext(host: host, endpoint: endpoint)
        }

        let age = now.timeIntervalSince(activeContext.receivedAt)
        guard age <= activeContextMaxAge else {
            return .staleActiveContext(host: host, activeParent: activeContext.parent, age: age)
        }

        if host == activeContext.parent {
            return .matchActiveParent(host: host, parent: activeContext.parent, age: age)
        }

        if activeContext.children.contains(host) {
            return .matchActiveChild(host: host, parent: activeContext.parent, age: age)
        }

        return .noActiveMatch(
            host: host,
            activeParent: activeContext.parent,
            childCount: activeContext.children.count,
            age: age
        )
    }
}
