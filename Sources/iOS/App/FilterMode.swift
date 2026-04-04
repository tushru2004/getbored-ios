//
//  FilterMode.swift
//  GetBored
//
//  Created by Tushar on 26.02.26.
//

import Foundation

// MARK: - Filter Mode

enum FilterMode: String, Codable, CaseIterable {
    case blockSpecific = "blockSpecific"
    case whiteList = "whiteList"
}

// MARK: - Access Policy

/// A complete parental control ruleset. Each AccessPolicy bundles together:
/// - What to filter (`entries` — the domains)
/// - What to exempt (`exceptions` — specific URL paths to allow)
/// - How to filter (`mode` — block listed sites, or block everything except listed sites)
/// - Whether it's active (`isActive`)
struct AccessPolicy: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var description: String
    var entries: [String]
    var exceptions: [String]
    var isActive: Bool
    var createdAt: Date
    var mode: FilterMode

    private enum CodingKeys: String, CodingKey {
        case id, name, description, entries, exceptions, isActive, createdAt, mode
    }

    init(
        id: UUID,
        name: String,
        description: String,
        entries: [String],
        exceptions: [String] = [],
        isActive: Bool,
        createdAt: Date,
        mode: FilterMode = .blockSpecific
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.entries = entries
        self.exceptions = exceptions
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
        isActive = try container.decode(Bool.self, forKey: .isActive)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        mode = (try? container.decode(FilterMode.self, forKey: .mode)) ?? .blockSpecific
    }
}
