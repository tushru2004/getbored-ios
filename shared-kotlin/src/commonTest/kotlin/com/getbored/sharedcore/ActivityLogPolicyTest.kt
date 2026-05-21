package com.getbored.sharedcore

import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ActivityLogPolicyTest {
    private val policy = ActivityLogPolicy()
    private val json = Json { ignoreUnknownKeys = true }

    private fun entry(
        id: String = "00000000-0000-0000-0000-000000000001",
        displayDomain: String = "example.com",
        blocked: Boolean = true,
        reason: String = "Blocked by filter",
        sourceApp: String? = null,
        timestamp: Double = 0.0,
    ) = ActivityLogEntry(
        id = id,
        displayDomain = displayDomain,
        blocked = blocked,
        reason = reason,
        sourceApp = sourceApp,
        timestamp = timestamp,
    )

    // ── stripTeamID ──────────────────────────────────────────────────────────

    @Test
    fun stripTeamIDReturnsNullForNullInput() {
        assertNull(policy.stripTeamID(null))
    }

    @Test
    fun stripTeamIDReturnsNullForEmptyInput() {
        assertNull(policy.stripTeamID(""))
    }

    @Test
    fun stripTeamIDStripsComPrefix() {
        assertEquals("com.example.app", policy.stripTeamID("ABCD1234.com.example.app"))
    }

    @Test
    fun stripTeamIDStripsOrgPrefix() {
        assertEquals("org.mozilla.firefox", policy.stripTeamID("TEAMID99.org.mozilla.firefox"))
    }

    @Test
    fun stripTeamIDStripsNetPrefix() {
        assertEquals("net.example.tool", policy.stripTeamID("XY12AB34.net.example.tool"))
    }

    @Test
    fun stripTeamIDFindsFirstKnownPrefixAnywhere() {
        // "io." appears inside the identifier — should return from that index onward
        assertEquals("io.example.app", policy.stripTeamID("ZZZZZZZZ.io.example.app"))
    }

    @Test
    fun stripTeamIDStripsTeamIDPatternWhenNoKnownPrefix() {
        // 8-char all-uppercase-or-digit first component, >= 3 parts, no known prefix
        assertEquals("foo.example", policy.stripTeamID("ABCD1234.foo.example"))
    }

    @Test
    fun stripTeamIDPassesThroughWhenFirstComponentTooShort() {
        // Only 7 chars — doesn't meet 8-char threshold
        assertEquals("ABCD123.foo.example", policy.stripTeamID("ABCD123.foo.example"))
    }

    @Test
    fun stripTeamIDPassesThroughWhenFirstComponentContainsLowercase() {
        // Has lowercase letter — not a team ID
        assertEquals("abcD1234.foo.example", policy.stripTeamID("abcD1234.foo.example"))
    }

    @Test
    fun stripTeamIDPassesThroughWhenFewerThanThreeParts() {
        // Only 2 parts after split — no strip
        assertEquals("ABCD1234.foo", policy.stripTeamID("ABCD1234.foo"))
    }

    @Test
    fun stripTeamIDPassesThroughPlainIdentifierWithNoPrefix() {
        assertEquals("unknown-identifier", policy.stripTeamID("unknown-identifier"))
    }

    @Test
    fun stripTeamIDStripsDePrefix() {
        assertEquals("de.some.app", policy.stripTeamID("TEAMIDXX.de.some.app"))
    }

    // ── ActivityLogEntry Swift-compatible decode defaults ───────────────────

    @Test
    fun decodeLegacyBlobFallsBackToDomainAndGeneratesSwiftDefaults() {
        val entry = json.decodeFromString<ActivityLogEntry>(
            """
            {
              "domain": "157.240.1.35",
              "blocked": true,
              "reason": "Blocked by filter"
            }
            """.trimIndent(),
        )

        assertEquals("157.240.1.35", entry.displayDomain)
        assertFalse(entry.isResolvableHostname)
        assertTrue(entry.timestamp > 0.0)
        assertTrue(uuidRegex.matches(entry.id))
    }

    @Test
    fun decodeMissingResolvableHostnameComputesTrueForDomainName() {
        val entry = json.decodeFromString<ActivityLogEntry>(
            """
            {
              "displayDomain": "example.com",
              "blocked": false,
              "reason": "Allowed"
            }
            """.trimIndent(),
        )

        assertTrue(entry.isResolvableHostname)
    }

    @Test
    fun decodeMissingResolvableHostnameComputesFalseForIPv6Address() {
        val entry = json.decodeFromString<ActivityLogEntry>(
            """
            {
              "displayDomain": "[2001:db8::1]",
              "blocked": true,
              "reason": "Blocked by filter"
            }
            """.trimIndent(),
        )

        assertFalse(entry.isResolvableHostname)
    }

    // ── mergeAndTrimEntries ──────────────────────────────────────────────────

    @Test
    fun mergeEmptyExistingWithNewEntriesReturnsAllNew() {
        val newEntries = listOf(
            entry(id = "ID-1", displayDomain = "a.com", timestamp = 2.0),
            entry(id = "ID-2", displayDomain = "b.com", timestamp = 1.0),
        )
        val result = policy.mergeAndTrimEntries(emptyList(), newEntries)
        assertEquals(newEntries, result)
    }

    @Test
    fun mergePrependsNewestNewEntriesBeforeExisting() {
        val existing = listOf(entry(id = "OLD", timestamp = 1.0))
        val new = listOf(entry(id = "NEW", timestamp = 2.0))
        val result = policy.mergeAndTrimEntries(existing, new)
        assertEquals("NEW", result[0].id)
        assertEquals("OLD", result[1].id)
    }

    @Test
    fun mergeBelowCapPreservesDuplicates() {
        // Swift only trims when size > maxTotal; duplicates survive if under cap
        val e = entry(id = "DUP", timestamp = 1.0)
        val result = policy.mergeAndTrimEntries(listOf(e), listOf(e), maxTotal = 500)
        assertEquals(2, result.size)
        assertEquals("DUP", result[0].id)
        assertEquals("DUP", result[1].id)
    }

    @Test
    fun mergeAboveCapDedupsWhenSameEntryExceedsPerAppLimit() {
        // One app contributes 60 entries — after per-app cap of 50, only 50 remain
        val appEntries = (1..60).map { i ->
            entry(id = "ID-$i", timestamp = i.toDouble(), sourceApp = "com.example.app")
        }
        // new = first 60, existing = empty. Total = 60 > default maxTotal(500)? No.
        // We need to exceed maxTotal. Use maxTotal=55 so 60 > 55.
        val result = policy.mergeAndTrimEntries(emptyList(), appEntries, maxTotal = 55, maxPerApp = 50)
        assertEquals(50, result.size)
    }

    @Test
    fun mergeTotalCapTrimsTo500() {
        // 600 entries total → trimmed to 500
        val existingEntries = (1..300).map { i ->
            entry(id = "OLD-$i", timestamp = i.toDouble(), sourceApp = "app.a")
        }
        val newEntries = (1..300).map { i ->
            entry(id = "NEW-$i", timestamp = (300 + i).toDouble(), sourceApp = "app.b")
        }
        // Each app has 300 entries, both under 50 per-app cap, but 600 > 500 total
        val result = policy.mergeAndTrimEntries(existingEntries, newEntries, maxTotal = 500, maxPerApp = 300)
        assertEquals(500, result.size)
    }

    @Test
    fun mergeNewEntriesAppearAtHeadOfResult() {
        val existing = (1..10).map { i -> entry(id = "OLD-$i", timestamp = i.toDouble()) }
        val new = (1..5).map { i -> entry(id = "NEW-$i", timestamp = (100 + i).toDouble()) }
        val result = policy.mergeAndTrimEntries(existing, new)
        // First 5 should be the new ones
        val headIds = result.take(5).map { it.id }
        assertEquals(listOf("NEW-1", "NEW-2", "NEW-3", "NEW-4", "NEW-5"), headIds)
    }

    @Test
    fun mergePerAppCapDropsOldestEntriesForOverloadedApp() {
        // 60 entries from one app; after per-app cap=50, oldest 10 dropped
        // "Oldest" means entries at higher indices (since new are prepended)
        val appEntries = (1..60).map { i ->
            entry(id = "ID-$i", timestamp = i.toDouble(), sourceApp = "com.heavy.app")
        }
        val result = policy.mergeAndTrimEntries(emptyList(), appEntries, maxTotal = 55, maxPerApp = 50)
        // The first 50 in the combined list survive; IDs 51-60 are dropped
        assertEquals(50, result.size)
        assertEquals("ID-1", result.first().id)
        assertEquals("ID-50", result.last().id)
    }

    @Test
    fun mergeNullSourceAppGroupedUnderSameKey() {
        // Entries with null sourceApp all count against the __nil__ bucket
        val nullAppEntries = (1..60).map { i ->
            entry(id = "ID-$i", timestamp = i.toDouble(), sourceApp = null)
        }
        val result = policy.mergeAndTrimEntries(emptyList(), nullAppEntries, maxTotal = 55, maxPerApp = 50)
        assertEquals(50, result.size)
    }

    @Test
    fun mergeMultipleAppsEachCappedIndependently() {
        // 40 entries from app A, 40 from app B = 80 total > maxTotal=70
        // Per-app cap = 50, so neither app exceeds per-app limit
        // Final trim to 70 applies
        val appA = (1..40).map { i -> entry(id = "A-$i", timestamp = i.toDouble(), sourceApp = "app.a") }
        val appB = (1..40).map { i -> entry(id = "B-$i", timestamp = i.toDouble(), sourceApp = "app.b") }
        val result = policy.mergeAndTrimEntries(emptyList(), appA + appB, maxTotal = 70, maxPerApp = 50)
        assertEquals(70, result.size)
    }

    companion object {
        private val uuidRegex = Regex(
            "[0-9A-F]{8}-[0-9A-F]{4}-4[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}",
        )
    }
}
