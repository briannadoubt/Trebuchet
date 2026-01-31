//
//  TodoListStreaming.swift
//  Shared
//

import Foundation

/// Protocol for streaming TodoList state.
/// This is a workaround for Swift's distributed actor isolation restrictions.
public protocol TodoListStreaming: AnyObject, Sendable {
    func observeState() async -> AsyncStream<TodoList.State>
}

extension TodoList: @preconcurrency TodoListStreaming {}
