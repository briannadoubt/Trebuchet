//
//  TodoList.swift
//  TrebuchetDemoShared
//

import Foundation
import Trebuchet

/// A distributed actor that manages a list of todos with streaming state
@Trebuchet
public distributed actor TodoList {

    /// The state of the todo list
    public struct State: Codable, Sendable, Equatable {
        public var todos: [TodoItem]
        public var pendingCount: Int

        public init(todos: [TodoItem] = [], pendingCount: Int = 0) {
            self.todos = todos
            self.pendingCount = pendingCount
        }
    }

    /// The current state, automatically streamed to observers
    @StreamedState public var state: State = State()

    /// Get all todos
    public distributed func getTodos() -> [TodoItem] {
        state.todos
    }

    /// Add a new todo
    public distributed func addTodo(title: String) -> TodoItem {
        let todo = TodoItem(title: title)

        // Create a new state with the updated values
        var newState = state
        newState.todos.append(todo)
        newState.pendingCount = newState.todos.filter { !$0.isCompleted }.count

        // Assign to trigger the @StreamedState setter and notify subscribers
        state = newState

        return todo
    }

    /// Toggle the completion status of a todo
    public distributed func toggleTodo(id: UUID) -> TodoItem? {
        guard let index = state.todos.firstIndex(where: { $0.id == id }) else {
            return nil
        }

        var newState = state
        newState.todos[index].isCompleted.toggle()
        newState.pendingCount = newState.todos.filter { !$0.isCompleted }.count
        state = newState

        return state.todos[index]
    }

    /// Delete a todo
    public distributed func deleteTodo(id: UUID) -> Bool {
        guard let index = state.todos.firstIndex(where: { $0.id == id }) else {
            return false
        }

        var newState = state
        newState.todos.remove(at: index)
        newState.pendingCount = newState.todos.filter { !$0.isCompleted }.count
        state = newState

        return true
    }

    /// Update a todo's title
    public distributed func updateTodo(id: UUID, title: String) -> TodoItem? {
        guard let index = state.todos.firstIndex(where: { $0.id == id }) else {
            return nil
        }

        var newState = state
        newState.todos[index].title = title
        state = newState

        return state.todos[index]
    }

    /// Get count of incomplete todos
    public distributed func pendingCount() -> Int {
        state.pendingCount
    }

    /// Clear all completed todos
    public distributed func clearCompleted() -> Int {
        let before = state.todos.count

        var newState = state
        newState.todos.removeAll { $0.isCompleted }
        newState.pendingCount = newState.todos.filter { !$0.isCompleted }.count
        state = newState

        return before - newState.todos.count
    }
}
