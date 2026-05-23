package com.getbored.sharedcore

data class BlockedHostResolution(
    val displayDomain: String,
    val rawEndpoint: String?,
    val resolutionSource: String,
    val isResolvableHostname: Boolean,
)

class BlockedHostResolutionPolicy {
    private val decisionCore = DecisionCore()

    fun resolve(rawUrlHost: String?, rawEndpoint: String?, sourceApp: String?): BlockedHostResolution {
        val normalizedUrlHost = normalizedBlockedHost(rawUrlHost)
        val normalizedEndpoint = normalizedBlockedHost(rawEndpoint)

        if (normalizedUrlHost != null && isResolvableHost(normalizedUrlHost)) {
            return BlockedHostResolution(
                displayDomain = normalizedUrlHost,
                rawEndpoint = normalizedEndpoint,
                resolutionSource = "url-host",
                isResolvableHostname = true,
            )
        }

        if (normalizedEndpoint != null && isResolvableHost(normalizedEndpoint)) {
            return BlockedHostResolution(
                displayDomain = normalizedEndpoint,
                rawEndpoint = normalizedEndpoint,
                resolutionSource = "socket-endpoint",
                isResolvableHostname = true,
            )
        }

        val sourceAppLabel = sourceApp
            ?.takeIf { value -> value.isNotEmpty() }
            ?.let { value -> "app:$value" }
        val fallback = sourceAppLabel
            ?: normalizedUrlHost
            ?: normalizedEndpoint
            ?: "unknown-blocked-flow"
        return BlockedHostResolution(
            displayDomain = fallback,
            rawEndpoint = normalizedEndpoint ?: normalizedUrlHost,
            resolutionSource = if (sourceApp != null) "source-app-fallback" else "unresolved",
            isResolvableHostname = false,
        )
    }

    private fun normalizedBlockedHost(value: String?): String? {
        val host = value?.let { decisionCore.normalizeHost(it) } ?: return null
        return host.takeIf { normalized -> normalized.isNotEmpty() && normalized != "unknown" }
    }

    private fun isResolvableHost(host: String): Boolean {
        return !isIpAddress(host) && !host.startsWith("app:")
    }

    private fun isIpAddress(host: String): Boolean {
        val normalized = host.trim('[', ']', ' ', '.').lowercase()
        return isIpv4Address(normalized) || isIpv6Address(normalized)
    }

    private fun isIpv4Address(value: String): Boolean {
        val parts = value.split(".")
        if (parts.size != 4) return false
        return parts.all { part ->
            part.isNotEmpty() &&
                part.all { char -> char.isDigit() } &&
                part.toIntOrNull()?.let { number -> number in 0..255 } == true
        }
    }

    private fun isIpv6Address(value: String): Boolean {
        if (!value.contains(":")) return false
        return value.split(":").all { part ->
            part.isEmpty() || (part.length <= 4 && part.all { char -> char in '0'..'9' || char in 'a'..'f' })
        }
    }
}
