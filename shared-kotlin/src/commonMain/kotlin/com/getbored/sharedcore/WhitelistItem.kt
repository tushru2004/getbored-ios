package com.getbored.sharedcore

import kotlinx.serialization.Serializable

/**
 * Kotlin mirror of Sources/iOS/App/WhitelistItem.swift (Codable struct).
 *
 * Wire-format compatibility requirements (must round-trip byte-identical with Swift):
 *  - Keys: id, url, title, timestamp — all required (Swift uses synthesized Codable
 *    with no optionals).
 *  - `id` is encoded as an UPPERCASE UUID string (Swift's UUID.uuidString default,
 *    e.g. "550E8400-E29B-41D4-A716-446655440000").
 *  - `timestamp` is encoded as `Double` seconds since the Swift reference date
 *    (2001-01-01T00:00:00Z) — Swift's default JSONEncoder strategy for Date.
 *
 * Persisted at App Group key "whitelist_items" via WhitelistManager.swift.
 */
@Serializable
data class WhitelistItem(
    val id: String,
    val url: String,
    val title: String,
    val timestamp: Double,
)
