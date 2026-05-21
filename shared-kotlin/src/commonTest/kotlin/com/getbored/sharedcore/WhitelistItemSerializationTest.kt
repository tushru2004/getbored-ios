package com.getbored.sharedcore

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class WhitelistItemSerializationTest {
    private val json = Json { ignoreUnknownKeys = true }

    // ── Encode ───────────────────────────────────────────────────────────────

    @Test
    fun encodeProducesExpectedJsonKeys() {
        val item = WhitelistItem(
            id = "550E8400-E29B-41D4-A716-446655440000",
            url = "https://www.apple.com",
            title = "Apple",
            timestamp = 757_382_400.0,
        )
        val encoded = json.encodeToString(item)
        assertTrue(encoded.contains("\"id\""))
        assertTrue(encoded.contains("\"url\""))
        assertTrue(encoded.contains("\"title\""))
        assertTrue(encoded.contains("\"timestamp\""))
    }

    @Test
    fun encodeProducesCorrectFieldValues() {
        val item = WhitelistItem(
            id = "550E8400-E29B-41D4-A716-446655440000",
            url = "https://www.apple.com",
            title = "Apple",
            timestamp = 757_382_400.0,
        )
        val encoded = json.encodeToString(item)
        assertTrue(encoded.contains("\"550E8400-E29B-41D4-A716-446655440000\""))
        assertTrue(encoded.contains("\"https://www.apple.com\""))
        assertTrue(encoded.contains("\"Apple\""))
        // Verify timestamp survives round-trip (native may use scientific notation)
        val decoded = json.decodeFromString<WhitelistItem>(encoded)
        assertEquals(757_382_400.0, decoded.timestamp)
    }

    // ── Decode ───────────────────────────────────────────────────────────────

    @Test
    fun decodeSwiftStyleBlobPopulatesAllFields() {
        // Synthesized Swift-style JSON blob matching what JSONEncoder produces
        val blob = """
            {
                "id": "550E8400-E29B-41D4-A716-446655440000",
                "url": "https://www.github.com",
                "title": "GitHub",
                "timestamp": 757382400.0
            }
        """.trimIndent()
        val item = json.decodeFromString<WhitelistItem>(blob)
        assertEquals("550E8400-E29B-41D4-A716-446655440000", item.id)
        assertEquals("https://www.github.com", item.url)
        assertEquals("GitHub", item.title)
        assertEquals(757_382_400.0, item.timestamp)
    }

    @Test
    fun decodeToleratesUnknownKeys() {
        val blob = """
            {
                "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                "url": "https://example.com",
                "title": "Example",
                "timestamp": 0.0,
                "unknownFutureField": "ignored"
            }
        """.trimIndent()
        val item = json.decodeFromString<WhitelistItem>(blob)
        assertEquals("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", item.id)
        assertEquals("https://example.com", item.url)
    }

    // ── Round-trip ───────────────────────────────────────────────────────────

    @Test
    fun roundTripPreservesAllFields() {
        val original = WhitelistItem(
            id = "12345678-1234-1234-1234-123456789ABC",
            url = "https://www.school.example/math",
            title = "Math Class",
            timestamp = 123_456_789.5,
        )
        val encoded = json.encodeToString(original)
        val decoded = json.decodeFromString<WhitelistItem>(encoded)
        assertEquals(original, decoded)
    }

    @Test
    fun roundTripWithSpecialCharactersInTitle() {
        val original = WhitelistItem(
            id = "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF",
            url = "https://example.com/path?q=hello+world&lang=en",
            title = "Test & \"Quoted\" <Title>",
            timestamp = 0.0,
        )
        val encoded = json.encodeToString(original)
        val decoded = json.decodeFromString<WhitelistItem>(encoded)
        assertEquals(original, decoded)
    }

    @Test
    fun roundTripWithZeroTimestamp() {
        val original = WhitelistItem(
            id = "00000000-0000-0000-0000-000000000000",
            url = "https://a.com",
            title = "A",
            timestamp = 0.0,
        )
        val decoded = json.decodeFromString<WhitelistItem>(json.encodeToString(original))
        assertEquals(original, decoded)
    }

    @Test
    fun roundTripWithNegativeTimestamp() {
        // Swift reference date is 2001-01-01; negative values represent dates before that
        val original = WhitelistItem(
            id = "11111111-1111-1111-1111-111111111111",
            url = "https://b.com",
            title = "B",
            timestamp = -86_400.0,
        )
        val decoded = json.decodeFromString<WhitelistItem>(json.encodeToString(original))
        assertEquals(original, decoded)
    }

    // ── Multi-entry list round-trip ──────────────────────────────────────────

    @Test
    fun roundTripListOfWhitelistItems() {
        val items = listOf(
            WhitelistItem("ID-1", "https://a.com", "A", 100.0),
            WhitelistItem("ID-2", "https://b.com", "B", 200.0),
            WhitelistItem("ID-3", "https://c.com", "C", 300.0),
        )
        val encoded = json.encodeToString(items)
        val decoded = json.decodeFromString<List<WhitelistItem>>(encoded)
        assertEquals(items, decoded)
    }

    @Test
    fun decodeSwiftStyleArrayBlob() {
        val blob = """
            [
                {"id":"AA000000-0000-0000-0000-000000000001","url":"https://apple.com","title":"Apple","timestamp":757382400.0},
                {"id":"BB000000-0000-0000-0000-000000000002","url":"https://google.com","title":"Google","timestamp":757382401.0}
            ]
        """.trimIndent()
        val items = json.decodeFromString<List<WhitelistItem>>(blob)
        assertEquals(2, items.size)
        assertEquals("AA000000-0000-0000-0000-000000000001", items[0].id)
        assertEquals("https://google.com", items[1].url)
        assertEquals(757_382_401.0, items[1].timestamp)
    }
}
