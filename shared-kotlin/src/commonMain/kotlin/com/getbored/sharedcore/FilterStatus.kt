package com.getbored.sharedcore

enum class FilterRunState {
    ACTIVE,
    INACTIVE,
    CHECKING,
    ERROR,
}

enum class ICloudRunState {
    AVAILABLE,
    UNAVAILABLE,
    CHECKING,
}

data class FilterStatusViewModel(
    val filterState: String,
    val filterLabel: String,
    val icloudState: String,
    val icloudLabel: String,
) {
    fun toDictionary(): Map<String, String> = mapOf(
        "filterState" to filterState,
        "filterLabel" to filterLabel,
        "icloudState" to icloudState,
        "icloudLabel" to icloudLabel,
    )
}

class FilterStatusCore {
    fun viewModel(
        filterEnabled: Boolean?,
        filterErrorMessage: String?,
        icloudAvailable: Boolean?,
        icloudErrorMessage: String?,
    ): FilterStatusViewModel {
        val filterState = when {
            filterErrorMessage != null -> FilterRunState.ERROR
            filterEnabled == null -> FilterRunState.CHECKING
            filterEnabled -> FilterRunState.ACTIVE
            else -> FilterRunState.INACTIVE
        }

        val filterLabel = when (filterState) {
            FilterRunState.ACTIVE -> "Active & Protecting"
            FilterRunState.INACTIVE -> "Inactive"
            FilterRunState.CHECKING -> "Checking..."
            FilterRunState.ERROR -> filterErrorMessage ?: "Error"
        }

        val icloudState = when {
            icloudErrorMessage != null -> ICloudRunState.UNAVAILABLE
            icloudAvailable == null -> ICloudRunState.CHECKING
            icloudAvailable -> ICloudRunState.AVAILABLE
            else -> ICloudRunState.UNAVAILABLE
        }

        val icloudLabel = when (icloudState) {
            ICloudRunState.AVAILABLE -> "Connected"
            ICloudRunState.UNAVAILABLE -> icloudErrorMessage ?: "Not signed in"
            ICloudRunState.CHECKING -> "Checking..."
        }

        return FilterStatusViewModel(
            filterState = filterState.name.lowercase(),
            filterLabel = filterLabel,
            icloudState = icloudState.name.lowercase(),
            icloudLabel = icloudLabel,
        )
    }
}
