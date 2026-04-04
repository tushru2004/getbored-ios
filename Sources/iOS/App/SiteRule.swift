//
//  SiteRule.swift
//  GetBored
//
//  Created by Tushar on 26.02.26.
//

import Foundation

struct SiteRule: Identifiable, Codable {
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
