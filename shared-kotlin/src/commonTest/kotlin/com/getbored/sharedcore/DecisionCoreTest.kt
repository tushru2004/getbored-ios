package com.getbored.sharedcore

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class DecisionCoreTest {
    private val core = DecisionCore()

    private fun policy(
        siteRules: List<String> = emptyList(),
        filterModeRaw: String = "blockSpecific",
        exceptions: List<String> = emptyList(),
        allowedAppBundleIds: List<String> = emptyList(),
        ownAppBundlePrefixes: List<String> = listOf("com.getbored"),
        systemAllowedSuffixes: List<String> = emptyList(),
    ) = PolicySnapshot(
        siteRules = siteRules,
        filterModeRaw = filterModeRaw,
        exceptions = exceptions,
        allowedAppBundleIds = allowedAppBundleIds,
        ownAppBundlePrefixes = ownAppBundlePrefixes,
        systemAllowedSuffixes = systemAllowedSuffixes,
    )

    @Test
    fun hostRulesMatchExactAndSubdomainOnly() {
        assertTrue(core.matchesHostRule("github.com", "github.com"))
        assertTrue(core.matchesHostRule("https://www.github.com/tushru2004/GetBored", "github.com"))
        assertFalse(core.matchesHostRule("github.com.evil.example", "github.com"))
    }

    @Test
    fun normalizeHostStripsUrlPartsWhitespaceAndEdgeDots() {
        assertEquals(
            "www.github.com",
            core.normalizeHost("  HTTPS://WWW.GitHub.Com:443/tushru2004/GetBored?tab=readme  "),
        )
        assertEquals("school.example", core.normalizeHost(".School.Example."))
        assertEquals("", core.normalizeHost("..."))
    }

    @Test
    fun hostMatchesDomainUsesExactOrSubdomainBoundaries() {
        assertTrue(core.hostMatchesDomain("cdn.school.example", "school.example"))
        assertTrue(core.hostMatchesDomain("https://school.example/path", "SCHOOL.EXAMPLE"))
        assertFalse(core.hostMatchesDomain("evil-school.example", "school.example"))
        assertFalse(core.hostMatchesDomain("school.example.evil", "school.example"))
        assertFalse(core.hostMatchesDomain("", "school.example"))
        assertFalse(core.hostMatchesDomain("school.example", ""))
    }

    @Test
    fun normalizeChildPatternPreservesWildcardPrefixAndTrimsDots() {
        assertEquals("*.cdn.example", core.normalizeChildPattern("  *.CDN.Example. "))
        assertEquals("cdn.example", core.normalizeChildPattern(".cdn.example."))
        assertEquals("", core.normalizeChildPattern("*."))
        assertEquals("", core.normalizeChildPattern("..."))
    }

    @Test
    fun hostMatchesChildPatternSupportsWildcardAndDomainPatterns() {
        assertTrue(core.hostMatchesChildPattern("assets.cdn.example", "*.cdn.example"))
        assertTrue(core.hostMatchesChildPattern("cdn.example", "*.cdn.example"))
        assertTrue(core.hostMatchesChildPattern("img.media.example", "media.example"))
        assertFalse(core.hostMatchesChildPattern("evilcdn.example", "*.cdn.example"))
        assertFalse(core.hostMatchesChildPattern("cdn.example.evil", "*.cdn.example"))
        assertFalse(core.hostMatchesChildPattern("cdn.example", "*."))
    }

    @Test
    fun relatedKeywordHelpersMirrorLegacySecondLevelDomainMatching() {
        assertEquals("amazon", core.baseKeyword("https://www.amazon.de/shop"))
        assertEquals("google", core.baseKeyword("maps.google.com"))
        assertEquals("", core.baseKeyword("x.co"))
        assertEquals("", core.baseKeyword("localhost"))

        assertTrue(core.hostContainsRelatedKeyword("images-eu.ssl-images-amazon.com", "amazon.de"))
        assertTrue(
            core.hostContainsAnyRelatedKeyword(
                "fonts.gstatic-google.example",
                listOf("apple.com", "maps.google.com"),
            ),
        )
        assertFalse(core.hostContainsRelatedKeyword("cdn.example.com", "x.co"))
        assertFalse(core.hostContainsAnyRelatedKeyword("cdn.example.com", listOf("apple.com", "school.edu")))
    }

    @Test
    fun exceptionsMatchLegacyIosPrefixSemantics() {
        val exceptions = listOf("github.com/project")

        assertTrue(core.matchesException("https://www.github.com/project/issues", exceptions))
        assertTrue(core.matchesException("github.com/project?tab=readme", exceptions))
        assertTrue(core.matchesException("github.com/projectEvil", exceptions))
        assertFalse(core.matchesException("github.com/other", exceptions))
    }

    @Test
    fun blockSpecificBlocksOnlyListedHosts() {
        val siteRules = listOf("youtube.com")

        assertTrue(core.shouldBlock("m.youtube.com/watch", siteRules, "blockSpecific", emptyList()))
        assertFalse(core.shouldBlock("apple.com", siteRules, "blockSpecific", emptyList()))
    }

    @Test
    fun whiteListBlocksUnlistedHosts() {
        val siteRules = listOf("apple.com")

        assertFalse(core.shouldBlock("icloud.apple.com", siteRules, "whiteList", emptyList()))
        assertTrue(core.shouldBlock("youtube.com", siteRules, "whiteList", emptyList()))
    }

    @Test
    fun allowedAppsMatchTeamPrefixedBundleIdentifiers() {
        assertTrue(core.matchesAllowedApp("TEAMID.com.apple.mobilesafari", listOf("com.apple.mobilesafari")))
        assertFalse(core.matchesAllowedApp("com.example.other", listOf("com.apple.mobilesafari")))
    }

    @Test
    fun classifyHostAlwaysAllowsEmptyAndSystemHosts() {
        val policy = policy(
            siteRules = listOf("youtube.com"),
            systemAllowedSuffixes = listOf("icloud.com"),
        )

        assertEquals(
            PolicyDecision(PolicyDecisionKind.ALLOW, "Empty host"),
            core.classifyHost("", policy, allowedSafariParent = null),
        )
        assertEquals(
            PolicyDecision(PolicyDecisionKind.ALLOW, "System allowed"),
            core.classifyHost("p42-contacts.icloud.com", policy, allowedSafariParent = null),
        )
    }

    @Test
    fun classifyHostWhiteListAllowsListedHostsAndAllowedSafariChildren() {
        val policy = policy(
            siteRules = listOf("school.example"),
            filterModeRaw = "whiteList",
        )

        assertEquals(
            PolicyDecision(PolicyDecisionKind.ALLOW, "In allowed list"),
            core.classifyHost("cdn.school.example", policy, allowedSafariParent = null),
        )
        assertEquals(
            PolicyDecision(PolicyDecisionKind.ALLOW, "Child of allowed Safari parent school.example"),
            core.classifyHost("assets.example-cdn.test", policy, allowedSafariParent = "school.example"),
        )
        assertEquals(
            PolicyDecision(PolicyDecisionKind.BLOCK, "Block everything mode"),
            core.classifyHost("games.example", policy, allowedSafariParent = null),
        )
    }

    @Test
    fun classifyHostBlockSpecificLocksDownEmptyRulesAndBlocksListedHosts() {
        assertEquals(
            PolicyDecision(PolicyDecisionKind.BLOCK, "No entries (lockdown)"),
            core.classifyHost("apple.com", policy(), allowedSafariParent = null),
        )

        val policy = policy(siteRules = listOf("youtube.com"))
        assertEquals(
            PolicyDecision(PolicyDecisionKind.BLOCK, "In blocklist"),
            core.classifyHost("m.youtube.com", policy, allowedSafariParent = null),
        )
        assertEquals(
            PolicyDecision(PolicyDecisionKind.ALLOW, "Not listed"),
            core.classifyHost("apple.com", policy, allowedSafariParent = null),
        )
    }

    @Test
    fun shouldAllowAppAllowsGetBoredAppleSystemAndExplicitApps() {
        val policy = policy(
            allowedAppBundleIds = listOf("com.example.allowed"),
            ownAppBundlePrefixes = listOf("com.getbored"),
        )

        assertTrue(core.shouldAllowApp("group.com.getbored.ios", policy))
        assertTrue(core.shouldAllowApp("TEAMID.com.apple.Preferences", policy))
        assertTrue(core.shouldAllowApp("TEAMID.com.example.allowed", policy))
        assertFalse(core.shouldAllowApp("TEAMID.com.apple.mobilesafari", policy))
        assertFalse(core.shouldAllowApp("com.example.other", policy))
    }

    @Test
    fun shouldLogBlockedAppProbeOnlyForBlockedAppsInWhiteListMode() {
        val whiteListPolicy = policy(
            filterModeRaw = "whiteList",
            allowedAppBundleIds = listOf("com.example.allowed"),
        )
        val blockSpecificPolicy = policy(filterModeRaw = "blockSpecific")

        assertTrue(core.shouldLogBlockedAppProbe("com.example.blocked", whiteListPolicy))
        assertFalse(core.shouldLogBlockedAppProbe("TEAMID.com.example.allowed", whiteListPolicy))
        assertFalse(core.shouldLogBlockedAppProbe("com.example.blocked", blockSpecificPolicy))
        assertFalse(core.shouldLogBlockedAppProbe(null, whiteListPolicy))
        assertFalse(core.shouldLogBlockedAppProbe("", whiteListPolicy))
    }

    @Test
    fun directSafariProxyDecisionUsesAllowlistAndBlocklistSemantics() {
        val whiteListPolicy = policy(
            siteRules = listOf("school.example"),
            filterModeRaw = "whiteList",
            systemAllowedSuffixes = listOf("icloud.com"),
        )
        val blockSpecificPolicy = policy(
            siteRules = listOf("youtube.com"),
            filterModeRaw = "blockSpecific",
        )

        assertEquals(
            PolicyDecision(PolicyDecisionKind.ALLOW, "System allowed"),
            core.directSafariProxyDecision("setup.icloud.com", whiteListPolicy),
        )
        assertEquals(
            PolicyDecision(PolicyDecisionKind.ALLOW, "In allowed list"),
            core.directSafariProxyDecision("cdn.school.example", whiteListPolicy),
        )
        assertEquals(
            PolicyDecision(PolicyDecisionKind.BLOCK, "Not in allowed list"),
            core.directSafariProxyDecision("games.example", whiteListPolicy),
        )
        assertEquals(
            PolicyDecision(PolicyDecisionKind.BLOCK, "In blocklist"),
            core.directSafariProxyDecision("m.youtube.com", blockSpecificPolicy),
        )
        assertEquals(
            PolicyDecision(PolicyDecisionKind.ALLOW, "Not listed"),
            core.directSafariProxyDecision("apple.com", blockSpecificPolicy),
        )
    }

    @Test
    fun parentChildDecisionReportsMissingAndStaleContext() {
        assertEquals(
            ParentChildDecision(
                kind = ParentChildDecisionKind.NO_ACTIVE_CONTEXT,
                host = "static.example",
                endpoint = "203.0.113.10",
                activeParent = "",
                ageSeconds = 0.0,
                childCount = 0,
            ),
            core.parentChildDecision(
                host = "static.example",
                endpoint = "203.0.113.10",
                activeParent = null,
                activeChildren = listOf("cdn.example"),
                activeContextAgeSeconds = 2.0,
                activeContextMaxAgeSeconds = 10.0,
            ),
        )

        val stale = core.parentChildDecision(
            host = "static.example",
            endpoint = "203.0.113.10",
            activeParent = "school.example",
            activeChildren = listOf("cdn.example", "media.example"),
            activeContextAgeSeconds = 10.04,
            activeContextMaxAgeSeconds = 10.0,
        )

        assertEquals(ParentChildDecisionKind.STALE_ACTIVE_CONTEXT, stale.kind)
        assertFalse(stale.shouldAllow)
        assertEquals("staleActiveContext", stale.observationDecision)
        assertEquals("BLOCK_STALE host=static.example activeParent=school.example age=10.0", stale.event)
    }

    @Test
    fun parentChildDecisionAllowsActiveParentAndChildPatterns() {
        val parent = core.parentChildDecision(
            host = "SCHOOL.EXAMPLE",
            endpoint = "school.example",
            activeParent = "school.example",
            activeChildren = listOf("*.cdn.example"),
            activeContextAgeSeconds = 1.24,
            activeContextMaxAgeSeconds = 10.0,
        )
        val child = core.parentChildDecision(
            host = "assets.cdn.example",
            endpoint = "203.0.113.10",
            activeParent = "school.example",
            activeChildren = listOf("*.cdn.example"),
            activeContextAgeSeconds = 1.26,
            activeContextMaxAgeSeconds = 10.0,
        )

        assertEquals(ParentChildDecisionKind.MATCH_ACTIVE_PARENT, parent.kind)
        assertTrue(parent.shouldAllow)
        assertEquals("matchActiveParent", parent.observationDecision)
        assertEquals("ALLOW_PARENT host=school.example parent=school.example age=1.2", parent.event)

        assertEquals(ParentChildDecisionKind.MATCH_ACTIVE_CHILD, child.kind)
        assertTrue(child.shouldAllow)
        assertEquals("matchActiveChild", child.observationDecision)
        assertEquals("ALLOW_CHILD host=assets.cdn.example parent=school.example age=1.3", child.event)
    }

    @Test
    fun parentChildDecisionBlocksWhenActiveContextDoesNotMatch() {
        val decision = core.parentChildDecision(
            host = "unrelated.example",
            endpoint = "203.0.113.10",
            activeParent = "school.example",
            activeChildren = listOf("*.cdn.example", "media.example"),
            activeContextAgeSeconds = 4.0,
            activeContextMaxAgeSeconds = 10.0,
        )

        assertEquals(ParentChildDecisionKind.NO_ACTIVE_MATCH, decision.kind)
        assertFalse(decision.shouldAllow)
        assertEquals("noActiveMatch", decision.observationDecision)
        assertEquals(
            "BLOCK_NO_MATCH host=unrelated.example activeParent=school.example childCount=2 age=4.0",
            decision.event,
        )
    }
}
