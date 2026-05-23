package com.getbored.sharedcore

/**
 * Pure parsing helpers for the first outbound bytes observed by the iOS data
 * provider. Swift owns NetworkExtension verdicts; Kotlin owns byte/string policy.
 */
class NetworkPayloadPolicy {
    fun extractSni(byteValues: List<Int>): String? {
        if (byteValues.size <= 5) return null

        val bytes = byteValues.map { value -> value and 0xff }
        if (bytes[0] != 0x16 || bytes[5] != 0x01) return null

        var pos = 43
        if (pos >= bytes.size) return null

        val sessionIdLen = bytes[pos]
        pos += 1 + sessionIdLen
        if (pos + 2 > bytes.size) return null

        val cipherSuitesLen = (bytes[pos] shl 8) or bytes[pos + 1]
        pos += 2 + cipherSuitesLen
        if (pos + 1 > bytes.size) return null

        val compressionLen = bytes[pos]
        pos += 1 + compressionLen
        if (pos + 2 > bytes.size) return null

        val extensionsLen = (bytes[pos] shl 8) or bytes[pos + 1]
        pos += 2
        val extensionsEnd = minOf(pos + extensionsLen, bytes.size)

        while (pos + 4 <= extensionsEnd) {
            val extType = (bytes[pos] shl 8) or bytes[pos + 1]
            val extLen = (bytes[pos + 2] shl 8) or bytes[pos + 3]
            pos += 4

            if (extType == 0x0000) {
                if (pos + 5 > extensionsEnd) return null
                val nameLen = (bytes[pos + 3] shl 8) or bytes[pos + 4]
                val nameStart = pos + 5
                if (nameStart + nameLen > extensionsEnd) return null
                return bytes
                    .subList(nameStart, nameStart + nameLen)
                    .map { value -> value.toByte() }
                    .toByteArray()
                    .decodeToString()
            }

            pos += extLen
        }
        return null
    }

    fun extractHttpHost(rawAscii: String): String? {
        if (!looksLikeHttpRequest(rawAscii)) return null

        return rawAscii.lineSequence()
            .firstOrNull { line -> line.lowercase().startsWith("host:") }
            ?.drop(5)
            ?.trim()
            ?.substringBefore(":")
            ?.takeIf { host -> host.isNotEmpty() }
    }

    fun extractHttpFullUrl(rawAscii: String): String? {
        if (!looksLikeHttpRequest(rawAscii)) return null

        val lines = rawAscii.lines()
        val requestLine = lines.firstOrNull() ?: return null
        val parts = requestLine.split(" ")
        if (parts.size < 2) return null

        val host = extractHttpHost(rawAscii) ?: return null
        return host + parts[1]
    }

    private fun looksLikeHttpRequest(rawAscii: String): Boolean {
        return rawAscii.startsWith("GET ") ||
            rawAscii.startsWith("POST ") ||
            rawAscii.startsWith("HEAD ") ||
            rawAscii.startsWith("PUT ") ||
            rawAscii.startsWith("DELETE ") ||
            rawAscii.startsWith("CONNECT ")
    }
}
