//
//  TodoList.swift
//  TrebucheDemoShared
//

import Foundation
import Trebuche

/// A distributed actor that manages a list of todos
@Trebuchet
public distributed actor TodoList {

    /// The current list of todos
    private var todos: [TodoItem] = []

    /// Get all todos
    public distributed func getTodos() -> [TodoItem] {
        todos
    }

    /// Add a new todo
    public distributed func addTodo(title: String) -> TodoItem {
        let todo = TodoItem(title: title)
        todos.append(todo)
        return todo
    }

    /// Toggle the completion status of a todo
    public distributed func toggleTodo(id: UUID) -> TodoItem? {
        guard let index = todos.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        todos[index].isCompleted.toggle()
        return todos[index]
    }

    /// Delete a todo
    public distributed func deleteTodo(id: UUID) -> Bool {
        guard let index = todos.firstIndex(where: { $0.id == id }) else {
            return false
        }
        todos.remove(at: index)
        return true
    }

    /// Update a todo's title
    public distributed func updateTodo(id: UUID, title: String) -> TodoItem? {
        guard let index = todos.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        todos[index].title = title
        return todos[index]
    }

    /// Get count of incomplete todos
    public distributed func pendingCount() -> Int {
        todos.filter { !$0.isCompleted }.count
    }

    /// Clear all completed todos
    public distributed func clearCompleted() -> Int {
        let before = todos.count
        todos.removeAll { $0.isCompleted }
        return before - todos.count
    }
}
