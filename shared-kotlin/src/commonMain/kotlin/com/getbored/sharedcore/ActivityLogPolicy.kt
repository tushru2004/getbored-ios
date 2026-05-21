package com.getbored.sharedcore

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder

/**
 * Kotlin mirror of GetBoredCore.ActivityLogEntry (Swift Codable).
 *
 * Wire-format compatibility requirements (must round-trip byte-identical with Swift):
 *  - Keys: id, displayDomain, domain (legacy alias), rawEndpoint, resolutionSource,
 *    isResolvableHostname, blocked, reason, sourceApp, timestamp.
 *  - Swift's encoder writes BOTH `displayDomain` AND `domain` with the same value
 *    for backwards compatibility.
 *  - Swift's decoder accepts either `displayDomain` or `domain`, falling back to
 *    "unknown-host". We mirror that behavior here.
 *  - `sourceApp` and `rawEndpoint` are optional; Swift uses encodeIfPresent so they
 *    are OMITTED from JSON when null (never written as `null`).
 *  - `timestamp` is encoded as `Double` seconds since the Swift reference date
 *    (2001-01-01T00:00:00Z) — this is Swift's default JSONEncoder strategy for Date.
 *  - `id` is encoded as an UPPERCASE UUID string (Swift's UUID.uuidString default).
 *
 * Internal representation keeps `timestamp` as a Double (Swift reference-date seconds)
 * so that round-trip encode/decode is lossless.
 */
@Serializable(with = ActivityLogEntrySerializer::class)
data class ActivityLogEntry(
    val id: String,
    val displayDomain: String,
    val blocked: Boolean,
    val reason: String,
    val sourceApp: String? = null,
    val rawEndpoint: String? = null,
    val resolutionSource: String = "legacy",
    val isResolvableHostname: Boolean = true,
    val timestamp: Double,
)

@Serializable
private class ActivityLogEntrySurrogate(
    val id: String? = null,
    val displayDomain: String? = null,
    val domain: String? = null,
    val rawEndpoint: String? = null,
    val resolutionSource: String? = null,
    val isResolvableHostname: Boolean? = null,
    val blocked: Boolean? = null,
    val reason: String? = null,
    val sourceApp: String? = null,
    val timestamp: Double? = null,
)

object ActivityLogEntrySerializer : KSerializer<ActivityLogEntry> {
    override val descriptor: SerialDescriptor = ActivityLogEntrySurrogate.serializer().descriptor

    override fun serialize(encoder: Encoder, value: ActivityLogEntry) {
        val surrogate = ActivityLogEntrySurrogate(
            id = value.id,
            displayDomain = value.displayDomain,
            domain = value.displayDomain,
            rawEndpoint = value.rawEndpoint,
            resolutionSource = value.resolutionSource,
            isResolvableHostname = value.isResolvableHostname,
            blocked = value.blocked,
            reason = value.reason,
            sourceApp = value.sourceApp,
            timestamp = value.timestamp,
        )
        encoder.encodeSerializableValue(ActivityLogEntrySurrogate.serializer(), surrogate)
    }

    override fun deserialize(decoder: Decoder): ActivityLogEntry {
        val s = decoder.decodeSerializableValue(ActivityLogEntrySurrogate.serializer())
        return ActivityLogEntry(
            id = s.id ?: "",
            displayDomain = s.displayDomain ?: s.domain ?: "unknown-host",
            blocked = s.blocked ?: true,
            reason = s.reason ?: "Blocked by filter",
            sourceApp = s.sourceApp,
            rawEndpoint = s.rawEndpoint,
            resolutionSource = s.resolutionSource ?: "legacy",
            isResolvableHostname = s.isResolvableHostname ?: true,
            timestamp = s.timestamp ?: 0.0,
        )
    }
}

/**
 * Pure logic for activity-log maintenance. Ports Swift `IOSActivityLogger.stripTeamID`
 * and the trim/dedup loop inside `writeEntries` (IOSRuleStore.swift lines 336-350).
 *
 * Wire-format guarantee: `mergeAndTrimEntries` must produce a list whose JSON-encoded
 * form matches what Swift `writeEntries` would have written for the same inputs.
 */
class ActivityLogPolicy {
    /**
     * Port of Swift IOSActivityLogger.stripTeamID:
     *  1. Returns nil for null or empty input.
     *  2. Scans for the FIRST occurrence of any known top-level prefix
     *     ("com.", "org.", "net.", "de.", "io.", "me.", "app.", "co.", "uk.",
     *     "fr.", "jp.", "au.", "at.") and returns the substring from there.
     *     Matches the Swift behavior of `identifier.range(of: prefix)` which finds
     *     the prefix anywhere in the string.
     *  3. If no known prefix is found, checks for a team-ID pattern: if there are
     *     >= 3 dot-separated parts and the first part is >= 8 chars and consists
     *     entirely of uppercase letters or digits, drop it.
     *  4. Otherwise pass through.
     */
    fun stripTeamID(identifier: String?): String? {
        if (identifier.isNullOrEmpty()) return null

        val prefixes = listOf(
            "com.", "org.", "net.", "de.", "io.", "me.",
            "app.", "co.", "uk.", "fr.", "jp.", "au.", "at.",
        )
        for (prefix in prefixes) {
            val idx = identifier.indexOf(prefix)
            if (idx >= 0) {
                return identifier.substring(idx)
            }
        }

        val parts = identifier.split(".")
        if (parts.size >= 3) {
            val first = parts[0]
            if (first.length >= 8 && first.all { it.isUpperCase() || it.isDigit() }) {
                return parts.drop(1).joinToString(".")
            }
        }

        return identifier
    }

    /**
     * Port of the prepend-and-trim block in Swift IOSActivityLogger.writeEntries
     * (IOSRuleStore.swift lines 336-350):
     *
     *   existing = newEntries + existing
     *   if existing.count > maxEntries {
     *       let maxPerApp = 50
     *       var counts: [String: Int] = [:]
     *       existing = existing.filter { entry in
     *           let key = entry.sourceApp?.lowercased() ?? "__nil__"
     *           let count = counts[key, default: 0]
     *           counts[key] = count + 1
     *           return count < maxPerApp
     *       }
     *       if existing.count > maxEntries {
     *           existing = Array(existing.prefix(maxEntries))
     *       }
     *   }
     *
     * NOTE: Swift only runs the per-app trim when the combined list exceeds
     * `maxTotal`. If it stays under the cap, NO trimming happens — duplicates
     * (full equality) are preserved as-is. We mirror that exactly.
     */
    fun mergeAndTrimEntries(
        existing: List<ActivityLogEntry>,
        newEntries: List<ActivityLogEntry>,
        maxTotal: Int = 500,
        maxPerApp: Int = 50,
    ): List<ActivityLogEntry> {
        var combined: List<ActivityLogEntry> = newEntries + existing

        if (combined.size > maxTotal) {
            val counts = mutableMapOf<String, Int>()
            combined = combined.filter { entry ->
                val key = entry.sourceApp?.lowercase() ?: "__nil__"
                val count = counts.getOrElse(key) { 0 }
                counts[key] = count + 1
                count < maxPerApp
            }
            if (combined.size > maxTotal) {
                combined = combined.take(maxTotal)
            }
        }

        return combined
    }
}
