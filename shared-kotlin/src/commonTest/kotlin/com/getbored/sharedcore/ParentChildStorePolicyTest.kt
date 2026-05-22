package com.getbored.sharedcore

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ParentChildStorePolicyTest {
    private val policy = ParentChildStorePolicy()

    // ── helpers ──────────────────────────────────────────────────────────────

    private fun activeContextJson(
        parentDomain: String,
        childDomains: List<String>,
        url: String = "https://$parentDomain/",
        receivedAt: Double = 0.0,
    ) = """{"parentDomain":"$parentDomain","childDomains":${childDomains.toJsonArray()},"url":"$url","receivedAt":$receivedAt}"""

    private fun flowObservationJson(
        requestHost: String,
        parentDomain: String,
        decision: String = "matchActiveChild",
        endpoint: String = "https://endpoint.example.com/",
        observedAt: Double = 0.0,
    ) = """{"requestHost":"$requestHost","parentDomain":"$parentDomain","decision":"$decision","endpoint":"$endpoint","observedAt":$observedAt}"""

    private fun parentChildMapJson(
        schemaVersion: Int = 1,
        rules: List<Pair<String, List<String>>> = emptyList(),
        wildcards: List<Pair<String, String>> = emptyList(),
    ): String {
        val rulesJson = rules.joinToString(",") { (p, c) ->
            """{"p":"$p","c":${c.toJsonArray()}}"""
        }
        val wildcardsJson = wildcards.joinToString(",") { (p, c) ->
            """{"p":"$p","c":"$c"}"""
        }
        return """{"schemaVersion":$schemaVersion,"rules":[$rulesJson],"wildcards":[$wildcardsJson]}"""
    }

    private fun registryJson(entries: Map<String, List<String>>): String {
        val body = entries.entries.joinToString(",") { (k, v) ->
            """"$k":${v.toJsonArray()}"""
        }
        return "{$body}"
    }

    private fun List<String>.toJsonArray(): String =
        "[${joinToString(",") { "\"$it\"" }}]"

    // ── mergedChildren ───────────────────────────────────────────────────────

    @Test
    fun mergedChildrenEmptyRegistryAndEmptyActiveContextReturnsEmpty() {
        val result = policy.mergedChildren(
            parentChildMapJson = null,
            activeContextJson = null,
            registryJson = null,
            parentDomain = "parent.com",
        )
        assertTrue(result.isEmpty())
    }

    @Test
    fun mergedChildrenFromRegistryOnlyReturnsThem() {
        val registry = registryJson(mapOf("parent.com" to listOf("child1.com", "child2.com")))
        val result = policy.mergedChildren(
            parentChildMapJson = null,
            activeContextJson = null,
            registryJson = registry,
            parentDomain = "parent.com",
        )
        assertEquals(setOf("child1.com", "child2.com"), result)
    }

    @Test
    fun mergedChildrenFromActiveContextOnlyReturnsThem() {
        val active = activeContextJson("parent.com", listOf("child1.com", "child2.com"))
        val result = policy.mergedChildren(
            parentChildMapJson = null,
            activeContextJson = active,
            registryJson = null,
            parentDomain = "parent.com",
        )
        assertEquals(setOf("child1.com", "child2.com"), result)
    }

    @Test
    fun mergedChildrenDeduplicatesOverlappingRegistryAndActiveContext() {
        val active = activeContextJson("parent.com", listOf("child1.com", "child2.com"))
        val registry = registryJson(mapOf("parent.com" to listOf("child2.com", "child3.com")))
        val result = policy.mergedChildren(
            parentChildMapJson = null,
            activeContextJson = active,
            registryJson = registry,
            parentDomain = "parent.com",
        )
        assertEquals(setOf("child1.com", "child2.com", "child3.com"), result)
    }

    @Test
    fun mergedChildrenUnknownParentReturnsEmpty() {
        val registry = registryJson(mapOf("other.com" to listOf("child1.com")))
        val active = activeContextJson("other.com", listOf("child1.com"))
        val result = policy.mergedChildren(
            parentChildMapJson = null,
            activeContextJson = active,
            registryJson = registry,
            parentDomain = "unknown.com",
        )
        assertTrue(result.isEmpty())
    }

    @Test
    fun mergedChildrenStaticMapTakesPrecedenceOverDynamic() {
        // Static map has "static-child.com", registry has "dynamic-child.com"
        // Static result should win and dynamic should not appear
        val mapJson = parentChildMapJson(rules = listOf("parent.com" to listOf("static-child.com")))
        val registry = registryJson(mapOf("parent.com" to listOf("dynamic-child.com")))
        val active = activeContextJson("parent.com", listOf("active-child.com"))
        val result = policy.mergedChildren(
            parentChildMapJson = mapJson,
            activeContextJson = active,
            registryJson = registry,
            parentDomain = "parent.com",
        )
        assertEquals(setOf("static-child.com"), result)
    }

    @Test
    fun mergedChildrenEmptyStaticMapFallsThroughToDynamic() {
        // A valid parent-child map that has no matching entry for parent.com
        val mapJson = parentChildMapJson(rules = listOf("other.com" to listOf("static-child.com")))
        val registry = registryJson(mapOf("parent.com" to listOf("dynamic-child.com")))
        val result = policy.mergedChildren(
            parentChildMapJson = mapJson,
            activeContextJson = null,
            registryJson = registry,
            parentDomain = "parent.com",
        )
        assertEquals(setOf("dynamic-child.com"), result)
    }

    // ── childDomainRecentlyAllowedByActiveParent ─────────────────────────────────────────────────

    @Test
    fun childDomainRecentlyAllowedByActiveParentReturnsFreshMatch() {
        // observedAt=100.0, now=105.0, maxAge=60 → age=5.0 → within window
        val obs = flowObservationJson(
            requestHost = "cdn.child.com",
            parentDomain = "parent.com",
            decision = "matchActiveChild",
            observedAt = 100.0,
        )
        val active = activeContextJson("parent.com", listOf("child.com"))
        val registry = registryJson(mapOf("parent.com" to listOf("child.com")))
        val result = policy.childDomainRecentlyAllowedByActiveParent(
            flowObservationJson = obs,
            activeContextJson = active,
            parentChildMapJson = null,
            registryJson = registry,
            requestHost = "cdn.child.com",
            maxAgeSeconds = 60.0,
            nowEpochSeconds = 105.0,
        )
        assertNotNull(result)
        assertEquals("parent.com", result.parentDomain)
        assertEquals("cdn.child.com", result.requestHost)
        assertEquals(5.0, result.age)
    }

    @Test
    fun childDomainRecentlyAllowedByActiveParentReturnsNullWhenStale() {
        // observedAt=100.0, now=200.0, maxAge=60 → age=100 > 60 → stale
        val obs = flowObservationJson(
            requestHost = "cdn.child.com",
            parentDomain = "parent.com",
            observedAt = 100.0,
        )
        val active = activeContextJson("parent.com", listOf("child.com"))
        val registry = registryJson(mapOf("parent.com" to listOf("child.com")))
        val result = policy.childDomainRecentlyAllowedByActiveParent(
            flowObservationJson = obs,
            activeContextJson = active,
            parentChildMapJson = null,
            registryJson = registry,
            requestHost = "cdn.child.com",
            maxAgeSeconds = 60.0,
            nowEpochSeconds = 200.0,
        )
        assertNull(result)
    }

    @Test
    fun childDomainRecentlyAllowedByActiveParentReturnsNullWhenHostDoesNotMatchObservation() {
        val obs = flowObservationJson(
            requestHost = "cdn.other.com",
            parentDomain = "parent.com",
            observedAt = 100.0,
        )
        val active = activeContextJson("parent.com", listOf("child.com"))
        val result = policy.childDomainRecentlyAllowedByActiveParent(
            flowObservationJson = obs,
            activeContextJson = active,
            parentChildMapJson = null,
            registryJson = null,
            requestHost = "cdn.child.com",
            maxAgeSeconds = 60.0,
            nowEpochSeconds = 105.0,
        )
        assertNull(result)
    }

    @Test
    fun childDomainRecentlyAllowedByActiveParentReturnsNullWhenFlowObservationJsonMissing() {
        val active = activeContextJson("parent.com", listOf("child.com"))
        val result = policy.childDomainRecentlyAllowedByActiveParent(
            flowObservationJson = null,
            activeContextJson = active,
            parentChildMapJson = null,
            registryJson = null,
            requestHost = "cdn.child.com",
            maxAgeSeconds = 60.0,
            nowEpochSeconds = 105.0,
        )
        assertNull(result)
    }

    @Test
    fun childDomainRecentlyAllowedByActiveParentReturnsNullWhenFlowObservationJsonMalformed() {
        val result = policy.childDomainRecentlyAllowedByActiveParent(
            flowObservationJson = "{not valid json{{",
            activeContextJson = activeContextJson("parent.com", listOf("child.com")),
            parentChildMapJson = null,
            registryJson = null,
            requestHost = "cdn.child.com",
            maxAgeSeconds = 60.0,
            nowEpochSeconds = 105.0,
        )
        assertNull(result)
    }

    @Test
    fun childDomainRecentlyAllowedByActiveParentReturnsNullWhenDecisionIsNotMatchActiveChild() {
        val obs = flowObservationJson(
            requestHost = "cdn.child.com",
            parentDomain = "parent.com",
            decision = "matchActiveParent",
            observedAt = 100.0,
        )
        val active = activeContextJson("parent.com", listOf("child.com"))
        val result = policy.childDomainRecentlyAllowedByActiveParent(
            flowObservationJson = obs,
            activeContextJson = active,
            parentChildMapJson = null,
            registryJson = null,
            requestHost = "cdn.child.com",
            maxAgeSeconds = 60.0,
            nowEpochSeconds = 105.0,
        )
        assertNull(result)
    }

    @Test
    fun childDomainRecentlyAllowedByActiveParentReturnsNullWhenAgeIsNegative() {
        // now < observedAt → negative age
        val obs = flowObservationJson(
            requestHost = "cdn.child.com",
            parentDomain = "parent.com",
            observedAt = 200.0,
        )
        val active = activeContextJson("parent.com", listOf("child.com"))
        val registry = registryJson(mapOf("parent.com" to listOf("child.com")))
        val result = policy.childDomainRecentlyAllowedByActiveParent(
            flowObservationJson = obs,
            activeContextJson = active,
            parentChildMapJson = null,
            registryJson = registry,
            requestHost = "cdn.child.com",
            maxAgeSeconds = 60.0,
            nowEpochSeconds = 100.0,
        )
        assertNull(result)
    }

    // ── dynamicChildren ──────────────────────────────────────────────────────

    @Test
    fun dynamicChildrenEmptyParentReturnsEmpty() {
        val result = policy.dynamicChildren(
            activeContextJson = null,
            registryJson = null,
            parentDomain = "parent.com",
        )
        assertTrue(result.isEmpty())
    }

    @Test
    fun dynamicChildrenParentWithNChildren() {
        val active = activeContextJson("parent.com", listOf("child1.com", "child2.com", "child3.com"))
        val result = policy.dynamicChildren(
            activeContextJson = active,
            registryJson = null,
            parentDomain = "parent.com",
        )
        assertEquals(setOf("child1.com", "child2.com", "child3.com"), result)
    }

    @Test
    fun dynamicChildrenMissingParentInActiveContextYieldsEmpty() {
        // Active context has different parent
        val active = activeContextJson("other.com", listOf("child1.com"))
        val result = policy.dynamicChildren(
            activeContextJson = active,
            registryJson = null,
            parentDomain = "parent.com",
        )
        assertTrue(result.isEmpty())
    }

    @Test
    fun dynamicChildrenMalformedActiveContextJsonYieldsEmptyFromContext() {
        val result = policy.dynamicChildren(
            activeContextJson = "{bad json",
            registryJson = null,
            parentDomain = "parent.com",
        )
        assertTrue(result.isEmpty())
    }

    @Test
    fun dynamicChildrenMergesActiveContextAndRegistryChildren() {
        val active = activeContextJson("parent.com", listOf("active-child.com"))
        val registry = registryJson(mapOf("parent.com" to listOf("registry-child.com")))
        val result = policy.dynamicChildren(
            activeContextJson = active,
            registryJson = registry,
            parentDomain = "parent.com",
        )
        assertEquals(setOf("active-child.com", "registry-child.com"), result)
    }

    // ── registryChildren ────────────────────────────────────────────────────

    @Test
    fun registryChildrenNullJsonReturnsEmpty() {
        val result = policy.registryChildren(null, "parent.com")
        assertTrue(result.isEmpty())
    }

    @Test
    fun registryChildrenEmptyStringJsonReturnsEmpty() {
        val result = policy.registryChildren("", "parent.com")
        assertTrue(result.isEmpty())
    }

    @Test
    fun registryChildrenParentWithNChildren() {
        val registry = registryJson(mapOf("parent.com" to listOf("child1.com", "child2.com")))
        val result = policy.registryChildren(registry, "parent.com")
        assertEquals(setOf("child1.com", "child2.com"), result)
    }

    @Test
    fun registryChildrenMissingParentInBlobReturnsEmpty() {
        val registry = registryJson(mapOf("other.com" to listOf("child1.com")))
        val result = policy.registryChildren(registry, "parent.com")
        assertTrue(result.isEmpty())
    }

    @Test
    fun registryChildrenMalformedJsonReturnsEmpty() {
        val result = policy.registryChildren("{not: valid json{{", "parent.com")
        assertTrue(result.isEmpty())
    }

    @Test
    fun registryChildrenFiltersOutParentFromChildren() {
        // If a child normalizes to the same value as the parent, it is dropped
        val registry = registryJson(mapOf("parent.com" to listOf("parent.com", "child.com")))
        val result = policy.registryChildren(registry, "parent.com")
        assertEquals(setOf("child.com"), result)
    }

    @Test
    fun registryChildrenNormalizesChildHosts() {
        val registry = registryJson(mapOf("parent.com" to listOf("Child.COM", "  child2.com  ")))
        val result = policy.registryChildren(registry, "parent.com")
        assertEquals(setOf("child.com", "child2.com"), result)
    }

    // ── parentChildMapChildren ───────────────────────────────────────────────

    @Test
    fun parentChildMapChildrenNullJsonReturnsNull() {
        val result = policy.parentChildMapChildren(null, "parent.com")
        assertNull(result)
    }

    @Test
    fun parentChildMapChildrenMalformedJsonReturnsNull() {
        val result = policy.parentChildMapChildren("{bad}", "parent.com")
        assertNull(result)
    }

    @Test
    fun parentChildMapChildrenParentWithNChildrenFromRules() {
        val mapJson = parentChildMapJson(
            rules = listOf("parent.com" to listOf("child1.com", "child2.com")),
        )
        val result = policy.parentChildMapChildren(mapJson, "parent.com")
        assertNotNull(result)
        assertEquals(setOf("child1.com", "child2.com"), result)
    }

    @Test
    fun parentChildMapChildrenMissingParentInBlobReturnsEmptySet() {
        val mapJson = parentChildMapJson(rules = listOf("other.com" to listOf("child1.com")))
        val result = policy.parentChildMapChildren(mapJson, "parent.com")
        assertNotNull(result)
        assertTrue(result.isEmpty())
    }

    @Test
    fun parentChildMapChildrenHandlesWildcardEntries() {
        val mapJson = parentChildMapJson(wildcards = listOf("parent.com" to "*.child.com"))
        val result = policy.parentChildMapChildren(mapJson, "parent.com")
        assertNotNull(result)
        assertEquals(setOf("*.child.com"), result)
    }

    @Test
    fun parentChildMapChildrenHandlesEmptyRulesAndWildcards() {
        val mapJson = parentChildMapJson()
        val result = policy.parentChildMapChildren(mapJson, "parent.com")
        assertNotNull(result)
        assertTrue(result.isEmpty())
    }

    // ── legacyPayload ────────────────────────────────────────────────────────

    @Test
    fun legacyPayloadRoundTripsFieldsMatchingSwiftOutput() {
        // Swift reference: 2024-05-21T14:30:00Z = Unix 1716301800
        // Swift ref seconds = 1716301800 - 978307200 = 737994600
        val swiftRefSeconds = 737994600.0
        val context = ActivePageContext(
            parentDomain = "parent.com",
            childDomains = listOf("child1.com", "child2.com"),
            url = "https://parent.com/page",
            receivedAt = swiftRefSeconds,
        )
        val probe = policy.legacyPayload(context)

        assertEquals("getbored.childRegistrationProbe", probe.type)
        assertEquals("https://parent.com/page", probe.url)
        assertEquals("parent.com", probe.parentDomain)
        assertEquals(listOf("child1.com", "child2.com"), probe.childDomains)
        assertEquals("safari-extension", probe.source)
        assertEquals("2024-05-21T14:30:00Z", probe.receivedAt)
    }

    @Test
    fun legacyPayloadAtSwiftReferenceEpochProducesCorrectIso8601() {
        // swiftRefSeconds=0.0 → 2001-01-01T00:00:00Z
        val context = ActivePageContext(
            parentDomain = "example.com",
            childDomains = emptyList(),
            url = "https://example.com/",
            receivedAt = 0.0,
        )
        val probe = policy.legacyPayload(context)
        assertEquals("2001-01-01T00:00:00Z", probe.receivedAt)
    }

    @Test
    fun legacyPayloadFloorsSubSecondPrecision() {
        // swiftRefSeconds = 0.9 should floor to 0 → 2001-01-01T00:00:00Z
        val context = ActivePageContext(
            parentDomain = "example.com",
            childDomains = emptyList(),
            url = "https://example.com/",
            receivedAt = 0.9,
        )
        val probe = policy.legacyPayload(context)
        assertEquals("2001-01-01T00:00:00Z", probe.receivedAt)
    }

    @Test
    fun legacyPayloadPreservesEmptyChildDomains() {
        val context = ActivePageContext(
            parentDomain = "parent.com",
            childDomains = emptyList(),
            url = "https://parent.com/",
            receivedAt = 0.0,
        )
        val probe = policy.legacyPayload(context)
        assertTrue(probe.childDomains.isEmpty())
    }

    // ── iso8601FromSwiftReferenceSeconds (companion) ─────────────────────────

    @Test
    fun iso8601ReferenceEpochIsJan2001() {
        val result = ParentChildStorePolicy.iso8601FromSwiftReferenceSeconds(0.0)
        assertEquals("2001-01-01T00:00:00Z", result)
    }

    @Test
    fun iso8601OneDayAfterReferenceEpoch() {
        val result = ParentChildStorePolicy.iso8601FromSwiftReferenceSeconds(86400.0)
        assertEquals("2001-01-02T00:00:00Z", result)
    }

    @Test
    fun iso8601KnownTimestampMay2024() {
        // 2024-05-21T14:30:00Z = Unix 1716301800; Swift ref = 1716301800 - 978307200 = 737994600
        val result = ParentChildStorePolicy.iso8601FromSwiftReferenceSeconds(737994600.0)
        assertEquals("2024-05-21T14:30:00Z", result)
    }

    @Test
    fun iso8601FloorsTruncatesSubSeconds() {
        // Same expected output as whole-second variant
        val whole = ParentChildStorePolicy.iso8601FromSwiftReferenceSeconds(737994600.0)
        val fractional = ParentChildStorePolicy.iso8601FromSwiftReferenceSeconds(737994600.999)
        assertEquals(whole, fractional)
    }

    // ── wire-format compatibility ────────────────────────────────────────────

    @Test
    fun flowObservationDecodesFromSwiftExactWireFormat() {
        // Mirrors Swift's synthesized Codable encode output: property declaration order
        // requestHost, parentDomain, decision, endpoint, observedAt
        val wireJson = """
            {
              "requestHost": "cdn.example.com",
              "parentDomain": "example.com",
              "decision": "matchActiveChild",
              "endpoint": "https://api.example.com/",
              "observedAt": 737994600.0
            }
        """.trimIndent()

        val result = policy.childDomainRecentlyAllowedByActiveParent(
            flowObservationJson = wireJson,
            activeContextJson = activeContextJson("example.com", listOf("example.com")),
            parentChildMapJson = null,
            registryJson = registryJson(mapOf("example.com" to listOf("cdn.example.com"))),
            requestHost = "cdn.example.com",
            maxAgeSeconds = 60.0,
            nowEpochSeconds = 737994605.0,
        )
        assertNotNull(result)
        assertEquals("cdn.example.com", result.requestHost)
        assertEquals("example.com", result.parentDomain)
        assertEquals(5.0, result.age)
    }

    @Test
    fun parentChildMapDecodesFromSwiftExactWireFormat() {
        // Mirrors Swift's ParentChildMap Codable output with optional fields present
        val wireJson = """
            {
              "schemaVersion": 2,
              "version": "1.0.0",
              "publishedAt": "2024-05-01",
              "rules": [
                {"p": "parent.com", "c": ["child1.com", "child2.com"]}
              ],
              "wildcards": [
                {"p": "parent.com", "c": "*.cdn.com"}
              ]
            }
        """.trimIndent()

        val result = policy.parentChildMapChildren(wireJson, "parent.com")
        assertNotNull(result)
        assertEquals(setOf("child1.com", "child2.com", "*.cdn.com"), result)
    }

    @Test
    fun parentChildMapDecodesWhenOptionalFieldsAbsent() {
        // version, publishedAt, wildcards are Swift optionals — omitted from JSON
        val wireJson = """
            {
              "schemaVersion": 1,
              "rules": [
                {"p": "parent.com", "c": ["child.com"]}
              ]
            }
        """.trimIndent()

        val result = policy.parentChildMapChildren(wireJson, "parent.com")
        assertNotNull(result)
        assertEquals(setOf("child.com"), result)
    }

    @Test
    fun activePageContextDecodesFromSwiftExactWireFormat() {
        // Mirrors Swift ActivePageContext: parentDomain, childDomains, url, receivedAt
        val wireJson = """
            {
              "parentDomain": "parent.com",
              "childDomains": ["child1.com", "child2.com"],
              "url": "https://parent.com/page",
              "receivedAt": 737994600.0
            }
        """.trimIndent()

        val result = policy.dynamicChildren(
            activeContextJson = wireJson,
            registryJson = null,
            parentDomain = "parent.com",
        )
        assertEquals(setOf("child1.com", "child2.com"), result)
    }

    @Test
    fun activePageContextRequiresTypedSwiftWireFormatNotLegacyPayload() {
        val legacyJson = """
            {
              "type": "getbored.childRegistrationProbe",
              "url": "https://parent.com/page",
              "parentDomain": "parent.com",
              "childDomains": ["child1.com", "child2.com"],
              "source": "safari-extension",
              "receivedAt": "2024-05-21T14:30:00Z"
            }
        """.trimIndent()

        val result = policy.dynamicChildren(
            activeContextJson = legacyJson,
            registryJson = null,
            parentDomain = "parent.com",
        )
        assertTrue(result.isEmpty())
    }

    @Test
    fun registryDecodesFromSwiftCourierJsonFormat() {
        // Swift courier JSON-encodes the plist [String:[String]] dict before handing to Kotlin
        val wireJson = """{"parent.com":["child1.com","child2.com"]}"""
        val result = policy.registryChildren(wireJson, "parent.com")
        assertEquals(setOf("child1.com", "child2.com"), result)
    }
}
