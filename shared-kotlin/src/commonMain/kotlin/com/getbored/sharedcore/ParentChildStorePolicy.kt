package com.getbored.sharedcore

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

@Serializable
data class ActivePageContext(
    val parentDomain: String,
    val childDomains: List<String>,
    val url: String,
    val receivedAt: Double,
)

@Serializable
private data class FlowObservation(
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
private data class ParentChildMap(
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

    fun childDomainRecentlyAllowedByActiveParent(
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

    private fun dynamicChildren(
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

    private fun registryChildren(registryJson: String?, parentDomain: String): Set<String> {
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

    private fun parentChildMapChildren(parentChildMapJson: String?, parentDomain: String): Set<String>? {
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
