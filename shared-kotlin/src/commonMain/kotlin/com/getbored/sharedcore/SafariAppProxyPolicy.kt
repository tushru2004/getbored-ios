package com.getbored.sharedcore

data class SafariActiveContextRefreshDecision(
    val shouldRefresh: Boolean,
    val matchingRule: String,
    val ageSeconds: Double,
) {
    val event: String
        get() = "APP_PROXY_REFRESH_ACTIVE_CONTEXT rule=$matchingRule age=${format(ageSeconds)}"

    private fun format(value: Double): String {
        val rounded = kotlin.math.round(value * 10.0) / 10.0
        return rounded.toString()
    }
}

data class SafariRelayDecision(
    val shouldRelay: Boolean,
    val host: String,
    val primaryEvent: String,
    val outcomeEvent: String,
    val parentChildKind: ParentChildDecisionKind,
    val activeParent: String,
    val observationDecision: String,
    val shouldSaveFlowObservation: Boolean,
)

class SafariAppProxyPolicy {
    private val decisionCore = DecisionCore()

    fun hostFromEndpoint(endpoint: String): String? {
        val hostPort = endpoint.substringBefore(" ")
        if (!hostPort.contains(":")) return null
        val host = hostPort.substringBefore(":")
        return decisionCore.normalizeHost(host).takeIf { normalized -> normalized.isNotEmpty() }
    }

    fun activeContextRefreshDecision(
        host: String,
        activeParentDomain: String,
        siteRules: List<String>,
        activeContextAgeSeconds: Double,
        refreshAgeThresholdSeconds: Double,
    ): SafariActiveContextRefreshDecision {
        val matchingRule = siteRules
            .map { rule -> decisionCore.normalizeHost(rule) }
            .firstOrNull { rule ->
                rule.isNotEmpty() && decisionCore.hostMatchesDomain(activeParentDomain, rule)
            }
            ?: ""

        val shouldRefresh = matchingRule.isNotEmpty() &&
            decisionCore.hostMatchesDomain(host, matchingRule) &&
            activeContextAgeSeconds > refreshAgeThresholdSeconds

        return SafariActiveContextRefreshDecision(
            shouldRefresh = shouldRefresh,
            matchingRule = matchingRule,
            ageSeconds = activeContextAgeSeconds,
        )
    }

    fun relayDecision(
        endpoint: String,
        policy: PolicySnapshot,
        activeParent: String?,
        activeChildren: List<String>,
        activeContextAgeSeconds: Double,
        activeContextMaxAgeSeconds: Double,
    ): SafariRelayDecision {
        val host = hostFromEndpoint(endpoint)
        if (host == null) {
            return SafariRelayDecision(
                shouldRelay = false,
                host = "",
                primaryEvent = "BLOCK_UNSUPPORTED_ENDPOINT endpoint=$endpoint",
                outcomeEvent = "",
                parentChildKind = ParentChildDecisionKind.NO_ACTIVE_CONTEXT,
                activeParent = "",
                observationDecision = "unsupportedEndpoint",
                shouldSaveFlowObservation = false,
            )
        }

        val directDecision = decisionCore.directSafariProxyDecision(host, policy)
        if (directDecision.kind == PolicyDecisionKind.ALLOW) {
            return SafariRelayDecision(
                shouldRelay = true,
                host = host,
                primaryEvent = "APP_PROXY_ALLOW_DIRECT host=$host endpoint=$endpoint",
                outcomeEvent = "",
                parentChildKind = ParentChildDecisionKind.MATCH_ACTIVE_PARENT,
                activeParent = activeParent ?: "",
                observationDecision = "directAllow",
                shouldSaveFlowObservation = false,
            )
        }

        val parentChildDecision = decisionCore.parentChildDecision(
            host = host,
            endpoint = endpoint,
            activeParent = activeParent,
            activeChildren = activeChildren,
            activeContextAgeSeconds = activeContextAgeSeconds,
            activeContextMaxAgeSeconds = activeContextMaxAgeSeconds,
        )

        val outcomeEvent = when (parentChildDecision.kind) {
            ParentChildDecisionKind.MATCH_ACTIVE_PARENT ->
                "APP_PROXY_ALLOW_ACTIVE_PARENT host=$host endpoint=$endpoint"
            ParentChildDecisionKind.MATCH_ACTIVE_CHILD ->
                "APP_PROXY_ALLOW_ACTIVE_CHILD host=$host parent=${parentChildDecision.activeParent} endpoint=$endpoint"
            ParentChildDecisionKind.NO_ACTIVE_CONTEXT,
            ParentChildDecisionKind.STALE_ACTIVE_CONTEXT,
            ParentChildDecisionKind.NO_ACTIVE_MATCH ->
                "APP_PROXY_ALLOW_UNCLASSIFIED host=$host decision=${parentChildDecision.observationDecision} endpoint=$endpoint"
        }

        return SafariRelayDecision(
            shouldRelay = true,
            host = host,
            primaryEvent = parentChildDecision.event,
            outcomeEvent = outcomeEvent,
            parentChildKind = parentChildDecision.kind,
            activeParent = parentChildDecision.activeParent,
            observationDecision = parentChildDecision.observationDecision,
            shouldSaveFlowObservation = parentChildDecision.kind == ParentChildDecisionKind.MATCH_ACTIVE_CHILD,
        )
    }
}
