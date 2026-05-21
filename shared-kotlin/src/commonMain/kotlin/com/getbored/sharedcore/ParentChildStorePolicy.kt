package com.getbored.sharedcore

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

/**
 * Pure-logic helpers ported from Sources/iOS/Shared/SafariParentChildContextStore.swift.
 *
 * Wire-format compatibility requirements (must round-trip byte-identical with Swift):
 *  - `ActivePageContext` / `FlowObservation`: Swift Codable structs with `receivedAt` /
 *    `observedAt` encoded as `Double` seconds since the Swift reference date
 *    (2001-01-01T00:00:00Z). Field order on encode: parentDomain, childDomains, url,
 *    receivedAt (struct property order — Swift's synthesized Codable uses property
 *    declaration order). Decoders are tolerant of any key order.
 *  - `ParentChildMap`: Swift Codable, nested `Rule` ({ p, c: [String] }) and
 *    `Wildcard` ({ p, c: String }). `version`, `publishedAt`, `wildcards` are
 *    Swift optionals — encoded as `null`/omitted, decoded as missing-or-null.
 *  - Registry: Swift `UserDefaults.dictionary(forKey:)` returns a plist dict
 *    `[String: [String]]`. The Swift courier JSON-encodes that dict before
 *    handing it to Kotlin, yielding `{"parent.com": ["child1", "child2"]}`.
 *  - `ChildAllowMatch`: NOT Codable on the Swift side. Only used as an in-memory
 *    return value. Kotlin returns a data class with the same three fields
 *    (parentDomain, requestHost, age) so the Swift courier can repack into the
 *    Swift struct.
 *  - `legacyPayload`: Swift builds a `[String: Any]` dict for JSONSerialization
 *    with [.prettyPrinted, .sortedKeys]. `receivedAt` is encoded as an ISO8601
 *    string via `ISO8601DateFormatter()` (default options: UTC, no fractional
 *    seconds, e.g. "2024-05-21T14:30:00Z"). We return a `@Serializable` data
 *    class; the Swift courier owns final JSON formatting (the legacy blob is a
 *    debug "last message" string, never re-parsed by the policy logic).
 *
 * Host normalization, child-pattern normalization, and host/domain matching all
 * delegate to [DecisionCore] (the same routines Swift uses via
 * KMPDecisionCoreAdapter), so cross-language parity is guaranteed.
 */

@Serializable
data class ActivePageContext(
    val parentDomain: String,
    val childDomains: List<String>,
    val url: String,
    val receivedAt: Double,
)

@Serializable
data class FlowObservation(
    val requestHost: String,
    val parentDomain: String,
    val decision: String,
    val endpoint: String,
    val observedAt: Double,
)

data class ChildAllowMatch(
    val parentDomain: String,
    val requestHost: String,
    val age: Double,
)

@Serializable
data class ParentChildMap(
    val schemaVersion: Int,
    val version: String? = null,
    val publishedAt: String? = null,
    val rules: List<Rule>,
    val wildcards: List<Wildcard>? = null,
) {
    @Serializable
    data class Rule(val p: String, val c: List<String>)

    @Serializable
    data class Wildcard(val p: String, val c: String)
}

/**
 * Mirror of Swift's `legacyPayload(for:)`. Field order matches the Swift dict
 * literal (type, url, parentDomain, childDomains, source, receivedAt); the
 * Swift call site re-encodes with `.sortedKeys` so field order is informational
 * only on this side.
 */
@Serializable
data class LegacyChildRegistrationProbe(
    val type: String,
    val url: String,
    val parentDomain: String,
    val childDomains: List<String>,
    val source: String,
    val receivedAt: String,
)

class ParentChildStorePolicy {
    private val core = DecisionCore()
    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
    }

    /**
     * Port of Swift `mergedChildren(for:)` (lines 143-150).
     *
     *   if let staticChildren = parentChildMapChildren(for: parent), !staticChildren.isEmpty {
     *       return staticChildren
     *   }
     *   return dynamicChildren(for: parent)
     *
     * Static (parent-child map) takes precedence when non-empty; otherwise falls
     * back to dynamicChildren (active-context children ∪ legacy registry).
     */
    fun mergedChildren(
        parentChildMapJson: String?,
        activeContextJson: String?,
        registryJson: String?,
        parentDomain: String,
    ): Set<String> {
        val parent = core.normalizeHost(parentDomain)
        if (parent.isEmpty()) return emptySet()

        val staticChildren = parentChildMapChildren(parentChildMapJson, parent)
        if (staticChildren != null && staticChildren.isNotEmpty()) {
            return staticChildren
        }
        return dynamicChildren(activeContextJson, registryJson, parent)
    }

    /**
     * Port of Swift `freshChildAllowMatch(for:maxAge:now:)` (lines 209-227).
     *
     * Returns a [ChildAllowMatch] when:
     *  - The flow observation's decision is exactly "matchActiveChild"
     *  - `requestHost` matches the observation's `requestHost` per
     *    [DecisionCore.hostMatchesDomain]
     *  - `now - observedAt` is in `[0, maxAgeSeconds]` (Swift requires age >= 0)
     *  - Active context exists with the same parent as the observation
     *  - One of the merged children matches `requestHost` per
     *    [DecisionCore.hostMatchesChildPattern]
     *
     * `nowEpochSeconds` and the observation's `observedAt` must both be in the
     * same Swift-reference-date frame (Double seconds since 2001-01-01). The
     * Swift caller passes `Date().timeIntervalSinceReferenceDate` (or equivalent).
     */
    fun freshChildAllowMatch(
        flowObservationJson: String?,
        activeContextJson: String?,
        parentChildMapJson: String?,
        registryJson: String?,
        requestHost: String,
        maxAgeSeconds: Double,
        nowEpochSeconds: Double,
    ): ChildAllowMatch? {
        val host = core.normalizeHost(requestHost)
        if (host.isEmpty()) return null

        val observation = decode(FlowObservation.serializer(), flowObservationJson) ?: return null
        if (observation.decision != "matchActiveChild") return null
        if (!core.hostMatchesDomain(host, observation.requestHost)) return null

        val age = nowEpochSeconds - observation.observedAt
        if (age < 0.0 || age > maxAgeSeconds) return null

        val active = decode(ActivePageContext.serializer(), activeContextJson) ?: return null
        if (active.parentDomain != observation.parentDomain) return null

        val children = mergedChildren(
            parentChildMapJson = parentChildMapJson,
            activeContextJson = activeContextJson,
            registryJson = registryJson,
            parentDomain = active.parentDomain,
        )
        val anyMatch = children.any { childPattern -> core.hostMatchesChildPattern(host, childPattern) }
        if (!anyMatch) return null

        return ChildAllowMatch(
            parentDomain = observation.parentDomain,
            requestHost = host,
            age = age,
        )
    }

    /**
     * Port of Swift private `dynamicChildren(for:)` (lines 266-272).
     *
     *   var children = Set(active?.parentDomain == parent ? active?.childDomains ?? [] : [])
     *   children.formUnion(registryChildren(for: parent))
     *
     * Active-context children only contribute when the active parent equals the
     * normalized query parent.
     */
    fun dynamicChildren(
        activeContextJson: String?,
        registryJson: String?,
        parentDomain: String,
    ): Set<String> {
        val parent = core.normalizeHost(parentDomain)
        if (parent.isEmpty()) return emptySet()

        val active = decode(ActivePageContext.serializer(), activeContextJson)
        val activeChildren: Set<String> =
            if (active != null && active.parentDomain == parent) active.childDomains.toSet()
            else emptySet()

        return activeChildren + registryChildren(registryJson, parent)
    }

    /**
     * Port of Swift private `registryChildren(for:)` (lines 274-292).
     *
     * Swift reads `defaults.dictionary(forKey: legacyParentChildRegistryKey)` —
     * a plist `[String: Any]`. The lookup is keyed by the RAW `parentDomain`
     * (not normalized) — Swift's `dynamicChildren` already passed in a
     * normalized parent, so this matches. Children are normalized via
     * [DecisionCore.normalizeHost] and dropped if empty or equal to the parent.
     *
     * Swift accepts both `[String]` and `NSArray` of strings at the inner
     * lookup; the Kotlin side receives a JSON object whose values are always
     * arrays-of-strings (the Swift courier coerces the plist on its end), so
     * we accept a [JsonArray] of string primitives.
     */
    fun registryChildren(registryJson: String?, parentDomain: String): Set<String> {
        if (registryJson.isNullOrEmpty()) return emptySet()

        val root: JsonElement = try {
            json.parseToJsonElement(registryJson)
        } catch (_: Throwable) {
            return emptySet()
        }
        val obj = (root as? JsonObject) ?: return emptySet()

        val rawChildren = obj[parentDomain] ?: return emptySet()
        val array = (rawChildren as? JsonArray) ?: return emptySet()

        val out = mutableSetOf<String>()
        for (element in array) {
            val str = (element as? JsonPrimitive)?.contentOrNull ?: continue
            val normalized = core.normalizeHost(str)
            if (normalized.isEmpty() || normalized == parentDomain) continue
            out.add(normalized)
        }
        return out
    }

    /**
     * Port of Swift private `legacyPayload(for:)` (lines 303-312). Returns a
     * data class; the Swift courier owns final JSON formatting (the dest key
     * `safari_extension_spike_last_message` is a debug blob).
     */
    fun legacyPayload(context: ActivePageContext): LegacyChildRegistrationProbe {
        return LegacyChildRegistrationProbe(
            type = "getbored.childRegistrationProbe",
            url = context.url,
            parentDomain = context.parentDomain,
            childDomains = context.childDomains,
            source = "safari-extension",
            receivedAt = iso8601FromSwiftReferenceSeconds(context.receivedAt),
        )
    }

    /**
     * Port of Swift `parentChildMapChildren(for:)` (lines 163-185). Returns
     * null when the map JSON is missing or fails to parse (mirroring Swift's
     * `guard let map = loadParentChildMap()`), or when `parentDomain`
     * normalizes empty.
     *
     * Wildcards' `c` is normalized via [DecisionCore.normalizeChildPattern]
     * (preserves a leading "*."); rules' `c` entries are also normalized via
     * the same routine. Empty patterns are dropped.
     */
    fun parentChildMapChildren(parentChildMapJson: String?, parentDomain: String): Set<String>? {
        val parent = core.normalizeHost(parentDomain)
        if (parent.isEmpty()) return null

        val map = decode(ParentChildMap.serializer(), parentChildMapJson) ?: return null

        val children = mutableSetOf<String>()
        for (rule in map.rules) {
            if (!core.hostMatchesDomain(parent, rule.p)) continue
            for (c in rule.c) {
                val normalized = core.normalizeChildPattern(c)
                if (normalized.isNotEmpty()) children.add(normalized)
            }
        }
        for (wildcard in map.wildcards.orEmpty()) {
            if (!core.hostMatchesDomain(parent, wildcard.p)) continue
            val normalized = core.normalizeChildPattern(wildcard.c)
            if (normalized.isNotEmpty()) children.add(normalized)
        }
        return children
    }

    private fun <T> decode(serializer: kotlinx.serialization.DeserializationStrategy<T>, raw: String?): T? {
        if (raw.isNullOrEmpty()) return null
        return try {
            json.decodeFromString(serializer, raw)
        } catch (_: Throwable) {
            null
        }
    }

    companion object {
        /**
         * Swift `ISO8601DateFormatter()` defaults: UTC, no fractional seconds,
         * yyyy-MM-dd'T'HH:mm:ss'Z'. Truncates (floors) to whole seconds — Swift
         * does the same (the formatter discards sub-second precision).
         */
        internal fun iso8601FromSwiftReferenceSeconds(swiftRefSeconds: Double): String {
            val swiftReferenceUnixSeconds = 978_307_200L
            val unixSeconds = swiftReferenceUnixSeconds + kotlin.math.floor(swiftRefSeconds).toLong()
            return formatIso8601Utc(unixSeconds)
        }

        private fun formatIso8601Utc(unixSeconds: Long): String {
            val daysSinceEpoch: Long
            val secondOfDay: Int
            run {
                val secondsInDay = 86_400L
                var days = unixSeconds / secondsInDay
                var sod = (unixSeconds - days * secondsInDay).toInt()
                if (sod < 0) {
                    sod += secondsInDay.toInt()
                    days -= 1
                }
                daysSinceEpoch = days
                secondOfDay = sod
            }
            val (year, month, day) = civilFromDays(daysSinceEpoch)
            val hour = secondOfDay / 3600
            val minute = (secondOfDay % 3600) / 60
            val second = secondOfDay % 60
            return pad4(year) + "-" + pad2(month) + "-" + pad2(day) + "T" +
                pad2(hour) + ":" + pad2(minute) + ":" + pad2(second) + "Z"
        }

        // Howard Hinnant's date algorithm: days since 1970-01-01 → (y, m, d).
        // Supports the full proleptic Gregorian range; receivedAt in this code
        // is always within ~now ± a few minutes so range is not a concern.
        private fun civilFromDays(daysSinceEpoch: Long): Triple<Int, Int, Int> {
            val z = daysSinceEpoch + 719468L
            val era = (if (z >= 0) z else z - 146096L) / 146097L
            val doe = (z - era * 146097L).toInt()
            val yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
            val y = yoe + (era * 400L).toInt()
            val doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
            val mp = (5 * doy + 2) / 153
            val d = doy - (153 * mp + 2) / 5 + 1
            val m = if (mp < 10) mp + 3 else mp - 9
            val year = if (m <= 2) y + 1 else y
            return Triple(year, m, d)
        }

        private fun pad2(value: Int): String {
            val v = if (value < 0) 0 else value
            return if (v < 10) "0$v" else v.toString()
        }

        private fun pad4(value: Int): String {
            val v = if (value < 0) 0 else value
            return when {
                v < 10 -> "000$v"
                v < 100 -> "00$v"
                v < 1000 -> "0$v"
                else -> v.toString()
            }
        }
    }
}

