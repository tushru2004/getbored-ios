package com.getbored.sharedcore

enum class FilterMode {
    BLOCK_SPECIFIC,
    WHITE_LIST;

    companion object {
        fun fromRaw(value: String): FilterMode {
            return when (value) {
                "whiteList" -> WHITE_LIST
                else -> BLOCK_SPECIFIC
            }
        }
    }
}

enum class PolicyDecisionKind {
    ALLOW,
    BLOCK,
}

data class PolicyDecision(
    val kind: PolicyDecisionKind,
    val reason: String,
)

data class PolicySnapshot(
    val siteRules: List<String>,
    val filterModeRaw: String,
    val exceptions: List<String>,
    val allowedAppBundleIds: List<String>,
    val blockedAppBundleIds: List<String>,
    val ownAppBundlePrefixes: List<String>,
    val systemAllowedSuffixes: List<String>,
) {
    val filterMode: FilterMode = FilterMode.fromRaw(filterModeRaw)
    val hasAnyEntries: Boolean = siteRules.isNotEmpty()
}

enum class ParentChildDecisionKind {
    NO_ACTIVE_CONTEXT,
    STALE_ACTIVE_CONTEXT,
    MATCH_ACTIVE_PARENT,
    MATCH_ACTIVE_CHILD,
    NO_ACTIVE_MATCH,
}

data class ParentChildDecision(
    val kind: ParentChildDecisionKind,
    val host: String,
    val endpoint: String,
    val activeParent: String,
    val ageSeconds: Double,
    val childCount: Int,
) {
    val shouldAllow: Boolean =
        kind == ParentChildDecisionKind.MATCH_ACTIVE_PARENT ||
            kind == ParentChildDecisionKind.MATCH_ACTIVE_CHILD

    val observationDecision: String
        get() = when (kind) {
            ParentChildDecisionKind.MATCH_ACTIVE_PARENT -> "matchActiveParent"
            ParentChildDecisionKind.MATCH_ACTIVE_CHILD -> "matchActiveChild"
            ParentChildDecisionKind.NO_ACTIVE_CONTEXT -> "noActiveContext"
            ParentChildDecisionKind.STALE_ACTIVE_CONTEXT -> "staleActiveContext"
            ParentChildDecisionKind.NO_ACTIVE_MATCH -> "noActiveMatch"
        }

    val event: String
        get() = when (kind) {
            ParentChildDecisionKind.NO_ACTIVE_CONTEXT ->
                "BLOCK_NO_CONTEXT host=$host endpoint=$endpoint"
            ParentChildDecisionKind.STALE_ACTIVE_CONTEXT ->
                "BLOCK_STALE host=$host activeParent=$activeParent age=${format(ageSeconds)}"
            ParentChildDecisionKind.MATCH_ACTIVE_PARENT ->
                "ALLOW_PARENT host=$host parent=$activeParent age=${format(ageSeconds)}"
            ParentChildDecisionKind.MATCH_ACTIVE_CHILD ->
                "ALLOW_CHILD host=$host parent=$activeParent age=${format(ageSeconds)}"
            ParentChildDecisionKind.NO_ACTIVE_MATCH ->
                "BLOCK_NO_MATCH host=$host activeParent=$activeParent childCount=$childCount age=${format(ageSeconds)}"
        }

    private fun format(value: Double): String {
        val rounded = kotlin.math.round(value * 10.0) / 10.0
        return rounded.toString()
    }
}

/**
 * Kotlin POC mirror of GetBoredCore.DecisionCore.
 *
 * Keep this module pure: no CloudKit, no App Group, no NetworkExtension types.
 * Swift provider code should normalize Apple objects into strings/lists before
 * calling this boundary.
 */
class DecisionCore {
    fun classifyHost(host: String, policy: PolicySnapshot, allowedSafariParent: String?): PolicyDecision {
        val normalizedHost = normalizeHost(host)
        if (normalizedHost.isEmpty()) {
            return PolicyDecision(PolicyDecisionKind.ALLOW, "Empty host")
        }

        if (isSystemAllowed(normalizedHost, policy.systemAllowedSuffixes)) {
            return PolicyDecision(PolicyDecisionKind.ALLOW, "System allowed")
        }

        if (policy.filterMode == FilterMode.WHITE_LIST) {
            if (matchesSiteRule(normalizedHost, policy.siteRules)) {
                return PolicyDecision(PolicyDecisionKind.ALLOW, "In allowed list")
            }
            if (allowedSafariParent != null && allowedSafariParent.isNotEmpty()) {
                return PolicyDecision(PolicyDecisionKind.ALLOW, "Child of allowed Safari parent $allowedSafariParent")
            }
            return PolicyDecision(PolicyDecisionKind.BLOCK, "Block everything mode")
        }

        if (!policy.hasAnyEntries) {
            return PolicyDecision(PolicyDecisionKind.ALLOW, "Empty blocklist")
        }
        if (matchesSiteRule(normalizedHost, policy.siteRules)) {
            return PolicyDecision(PolicyDecisionKind.BLOCK, "In blocklist")
        }
        return PolicyDecision(PolicyDecisionKind.ALLOW, "Not listed")
    }

    fun shouldAllowApp(sourceApp: String, policy: PolicySnapshot): Boolean {
        val appLower = sourceApp.lowercase()

        if (policy.ownAppBundlePrefixes.any { prefix -> appLower.contains(prefix.lowercase()) }) {
            return true
        }

        if ((appLower.endsWith(".com.apple.") || appLower.contains(".com.apple.")) &&
            !appLower.contains("mobilesafari")
        ) {
            return true
        }

        return matchesAllowedApp(sourceApp, policy.allowedAppBundleIds)
    }

    fun shouldLogBlockedAppProbe(sourceApp: String?, policy: PolicySnapshot): Boolean {
        return !sourceApp.isNullOrEmpty() && policy.filterMode == FilterMode.WHITE_LIST && !shouldAllowApp(sourceApp, policy)
    }

    fun isSystemAllowed(host: String, systemAllowedSuffixes: List<String>): Boolean {
        val normalizedHost = normalizeHost(host)
        return systemAllowedSuffixes.any { suffix ->
            val normalizedSuffix = normalizeHost(suffix)
            normalizedHost == normalizedSuffix || normalizedHost.endsWith(".$normalizedSuffix")
        }
    }

    fun directSafariProxyDecision(host: String, policy: PolicySnapshot): PolicyDecision {
        val normalizedHost = normalizeHost(host)
        if (isSystemAllowed(normalizedHost, policy.systemAllowedSuffixes)) {
            return PolicyDecision(PolicyDecisionKind.ALLOW, "System allowed")
        }

        val listed = matchesSiteRule(normalizedHost, policy.siteRules)
        if (policy.filterMode == FilterMode.WHITE_LIST) {
            return if (listed) {
                PolicyDecision(PolicyDecisionKind.ALLOW, "In allowed list")
            } else {
                PolicyDecision(PolicyDecisionKind.BLOCK, "Not in allowed list")
            }
        }

        return if (listed) {
            PolicyDecision(PolicyDecisionKind.BLOCK, "In blocklist")
        } else {
            PolicyDecision(PolicyDecisionKind.ALLOW, "Not listed")
        }
    }

    fun parentChildDecision(
        host: String,
        endpoint: String,
        activeParent: String?,
        activeChildren: List<String>,
        activeContextAgeSeconds: Double,
        activeContextMaxAgeSeconds: Double,
    ): ParentChildDecision {
        val normalizedHost = normalizeHost(host)
        if (activeParent.isNullOrEmpty()) {
            return ParentChildDecision(
                kind = ParentChildDecisionKind.NO_ACTIVE_CONTEXT,
                host = normalizedHost,
                endpoint = endpoint,
                activeParent = "",
                ageSeconds = 0.0,
                childCount = 0,
            )
        }

        val normalizedParent = normalizeHost(activeParent)
        if (activeContextAgeSeconds > activeContextMaxAgeSeconds) {
            return ParentChildDecision(
                kind = ParentChildDecisionKind.STALE_ACTIVE_CONTEXT,
                host = normalizedHost,
                endpoint = endpoint,
                activeParent = normalizedParent,
                ageSeconds = activeContextAgeSeconds,
                childCount = activeChildren.size,
            )
        }

        if (normalizedHost == normalizedParent) {
            return ParentChildDecision(
                kind = ParentChildDecisionKind.MATCH_ACTIVE_PARENT,
                host = normalizedHost,
                endpoint = endpoint,
                activeParent = normalizedParent,
                ageSeconds = activeContextAgeSeconds,
                childCount = activeChildren.size,
            )
        }

        if (activeChildren.any { child -> hostMatchesChildPattern(normalizedHost, child) }) {
            return ParentChildDecision(
                kind = ParentChildDecisionKind.MATCH_ACTIVE_CHILD,
                host = normalizedHost,
                endpoint = endpoint,
                activeParent = normalizedParent,
                ageSeconds = activeContextAgeSeconds,
                childCount = activeChildren.size,
            )
        }

        return ParentChildDecision(
            kind = ParentChildDecisionKind.NO_ACTIVE_MATCH,
            host = normalizedHost,
            endpoint = endpoint,
            activeParent = normalizedParent,
            ageSeconds = activeContextAgeSeconds,
            childCount = activeChildren.size,
        )
    }

    fun shouldBlock(
        url: String,
        siteRules: List<String>,
        filterModeRaw: String,
        exceptions: List<String>
    ): Boolean {
        if (matchesException(url, exceptions)) {
            return false
        }

        val matchedSiteRule = matchesSiteRule(url, siteRules)

        return when (filterModeRaw) {
            "whiteList" -> !matchedSiteRule
            else -> matchedSiteRule
        }
    }

    fun matchesAllowedApp(bundleId: String, allowedAppBundleIds: List<String>): Boolean {
        val normalizedBundleId = bundleId.lowercase()

        return allowedAppBundleIds.any { stored ->
            val allowed = stored.lowercase()
            normalizedBundleId == allowed || normalizedBundleId.endsWith(".$allowed")
        }
    }

    fun isAppBlocked(sourceApp: String, policy: PolicySnapshot): Boolean {
        val normalizedBundleId = sourceApp.lowercase()

        return policy.blockedAppBundleIds.any { stored ->
            val blocked = stored.lowercase()
            normalizedBundleId == blocked || normalizedBundleId.endsWith(".$blocked")
        }
    }

    fun matchesException(url: String, exceptions: List<String>): Boolean {
        val normalizedUrl = normalizeUrlPrefix(url)

        return exceptions.any { exception ->
            val pattern = normalizeUrlPrefix(exception)
            pattern.isNotEmpty() && normalizedUrl.startsWith(pattern)
        }
    }

    fun matchesSiteRule(url: String, siteRules: List<String>): Boolean {
        return siteRules.any { rule -> matchesHostRule(url, rule) }
    }

    fun matchesHostRule(hostOrUrl: String, rule: String): Boolean {
        return hostMatchesDomain(hostOrUrl, rule)
    }

    fun normalizeHost(input: String): String {
        var value = input.trim().lowercase()

        val schemeIndex = value.indexOf("://")
        if (schemeIndex >= 0) {
            value = value.substring(schemeIndex + 3)
        }

        val slashIndex = value.indexOf("/")
        if (slashIndex >= 0) {
            value = value.substring(0, slashIndex)
        }

        val colonIndex = value.indexOf(":")
        if (colonIndex >= 0) {
            value = value.substring(0, colonIndex)
        }

        val questionIndex = value.indexOf("?")
        if (questionIndex >= 0) {
            value = value.substring(0, questionIndex)
        }

        return value.trim('.')
    }

    fun hostMatchesDomain(hostOrUrl: String, domainOrUrl: String): Boolean {
        val normalizedHost = normalizeHost(hostOrUrl)
        val normalizedDomain = normalizeHost(domainOrUrl)

        if (normalizedHost.isEmpty() || normalizedDomain.isEmpty()) {
            return false
        }

        return normalizedHost == normalizedDomain || normalizedHost.endsWith(".$normalizedDomain")
    }

    fun normalizeChildPattern(input: String): String {
        val raw = input.trim().lowercase()
        if (raw.isEmpty()) {
            return ""
        }

        if (raw.startsWith("*.")) {
            val suffix = raw.substring(2).trim('.')
            return if (suffix.isEmpty()) "" else "*.$suffix"
        }

        return raw.trim('.')
    }

    fun hostMatchesChildPattern(hostOrUrl: String, childPattern: String): Boolean {
        val normalizedHost = normalizeHost(hostOrUrl)
        val normalizedPattern = normalizeChildPattern(childPattern)
        if (normalizedHost.isEmpty() || normalizedPattern.isEmpty()) {
            return false
        }
        if (normalizedPattern.startsWith("*.")) {
            val suffix = normalizedPattern.substring(2)
            return normalizedHost == suffix || normalizedHost.endsWith(".$suffix")
        }
        return hostMatchesDomain(normalizedHost, normalizedPattern)
    }

    fun baseKeyword(domainOrUrl: String): String {
        val parts = normalizeHost(domainOrUrl)
            .split(".")
            .filter { part -> part.isNotEmpty() }
        if (parts.size < 2) {
            return ""
        }

        val secondLevelDomain = parts[parts.size - 2]
        return if (secondLevelDomain.length >= 4) secondLevelDomain else ""
    }

    fun hostContainsRelatedKeyword(hostOrUrl: String, domainOrUrl: String): Boolean {
        val keyword = baseKeyword(domainOrUrl)
        if (keyword.isEmpty()) {
            return false
        }
        return normalizeHost(hostOrUrl).contains(keyword)
    }

    fun hostContainsAnyRelatedKeyword(hostOrUrl: String, domainOrUrls: List<String>): Boolean {
        return domainOrUrls.any { domainOrUrl -> hostContainsRelatedKeyword(hostOrUrl, domainOrUrl) }
    }

    private fun normalizeUrlPrefix(input: String): String {
        var value = input.lowercase()

        val schemeIndex = value.indexOf("://")
        if (schemeIndex >= 0) {
            value = value.substring(schemeIndex + 3)
        }

        if (value.startsWith("www.")) {
            value = value.substring(4)
        }

        return value
    }
}
