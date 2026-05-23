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
}
