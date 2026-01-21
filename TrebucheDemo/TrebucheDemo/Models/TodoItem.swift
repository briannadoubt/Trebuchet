//
//  TodoItem.swift
//  TrebucheDemo
//
//  Created by Brianna Zamora on 1/20/26.
//

import Foundation

/// A single todo item
public nonisolated struct TodoItem: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var title: String
    public var isCompleted: Bool
    public var createdAt: Date

    public init(id: UUID = UUID(), title: String, isCompleted: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.isCompleted = isCompleted
        self.createdAt = createdAt
    }
}
