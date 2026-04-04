import Foundation

// MARK: - Filter List Mode (iOS copy)

enum FilterListMode: String, Codable, CaseIterable {
    case blockSpecific = "blockSpecific"
    case whiteList = "whiteList"
}

// MARK: - Filter Location Model (iOS copy)

struct FilterLocation: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var latitude: Double
    var longitude: Double
    var radiusMeters: Double

    init(id: UUID = UUID(), name: String, latitude: Double, longitude: Double, radiusMeters: Double = 200) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
    }
}

// MARK: - Filter List Model (iOS copy)

struct FilterList: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var description: String
    var entries: [String]
    var exceptions: [String]
    var locations: [FilterLocation]
    var isActive: Bool
    var createdAt: Date
    var mode: FilterListMode

    private enum CodingKeys: String, CodingKey {
        case id, name, description, entries, exceptions, locations, isActive, createdAt, mode
    }

    init(id: UUID, name: String, description: String, entries: [String], exceptions: [String] = [], locations: [FilterLocation] = [], isActive: Bool, createdAt: Date, mode: FilterListMode = .blockSpecific) {
        self.id = id
        self.name = name
        self.description = description
        self.entries = entries
        self.exceptions = exceptions
        self.locations = locations
        self.isActive = isActive
        self.createdAt = createdAt
        self.mode = mode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        entries = try container.decode([String].self, forKey: .entries)
        exceptions = (try? container.decode([String].self, forKey: .exceptions)) ?? []
        locations = (try? container.decode([FilterLocation].self, forKey: .locations)) ?? []
        isActive = try container.decode(Bool.self, forKey: .isActive)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        mode = (try? container.decode(FilterListMode.self, forKey: .mode)) ?? .blockSpecific
    }
}
