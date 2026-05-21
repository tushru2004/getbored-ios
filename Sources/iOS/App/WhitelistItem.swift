import Foundation
#if canImport(GetBoredSharedCore)
import GetBoredSharedCore
#endif

struct WhitelistItem: Identifiable, Codable {
    let id: UUID
    let url: String
    let title: String
    let timestamp: Date

    init(id: UUID = UUID(), url: String, title: String, timestamp: Date = Date()) {
        self.id = id
        self.url = url
        self.title = title
        self.timestamp = timestamp
    }
}

#if canImport(GetBoredSharedCore)
extension WhitelistItem {
    /// Convert to the Kotlin DTO for crossing the KMP boundary.
    func toKotlin() -> GetBoredSharedCore.WhitelistItem {
        GetBoredSharedCore.WhitelistItem(
            id: id.uuidString,
            url: url,
            title: title,
            timestamp: timestamp.timeIntervalSinceReferenceDate
        )
    }

    /// Convert from the Kotlin DTO back to the Swift value type.
    init(kotlin item: GetBoredSharedCore.WhitelistItem) {
        self.id = UUID(uuidString: item.id) ?? UUID()
        self.url = item.url
        self.title = item.title
        self.timestamp = Date(timeIntervalSinceReferenceDate: item.timestamp)
    }
}
#endif
