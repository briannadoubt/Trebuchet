//
//  TodoListView.swift
//  TrebuchetDemo
//
//  Created by Brianna Zamora on 1/20/26.
//

import SwiftUI
import Trebuchet
import Shared

struct TodoListView: View {
    /// The remote TodoList actor with streaming state - automatically updates in realtime
    @ObservedActor<TodoList, TodoList.State>(
        id: "todos",
        property: "state"
    ) var state

    /// State for showing the add todo sheet
    @State private var showingAddTodo = false

    var body: some View {
        NavigationStack {
            Group {
                if $state.isConnecting {
                    ProgressView("Connecting...")
                } else if let error = $state.error {
                    ContentUnavailableView(
                        "Error",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error.localizedDescription)
                    )
                } else if let currentState = state {
                    todoListContent(state: currentState)
                } else {
                    ContentUnavailableView(
                        "Disconnected",
                        systemImage: "wifi.slash",
                        description: Text("Unable to connect to the server")
                    )
                }
            }
            .navigationTitle("Todos")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddTodo = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled($state.actor == nil)
                }

                ToolbarItem(placement: .secondaryAction) {
                    Button("Clear Completed") {
                        Task { await clearCompleted() }
                    }
                    .disabled(state?.todos.filter(\.isCompleted).isEmpty ?? true)
                }
            }
            .sheet(isPresented: $showingAddTodo) {
                AddTodoView { title in
                    Task { await addTodo(title: title) }
                }
            }
        }
    }

    @ViewBuilder
    private func todoListContent(state: TodoList.State) -> some View {
        if state.todos.isEmpty {
            ContentUnavailableView(
                "No Todos",
                systemImage: "checklist",
                description: Text("Tap + to add your first todo")
            )
        } else {
            List {
                ForEach(state.todos) { todo in
                    TodoRowView(
                        todo: todo,
                        onToggle: { Task { await toggleTodo(id: todo.id) } },
                        onDelete: { Task { await deleteTodo(id: todo.id) } }
                    )
                }

                Section {
                    Text("\(state.pendingCount) remaining")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            #if !os(macOS)
            .listStyle(.insetGrouped)
            #endif
        }
    }

    // MARK: - Actions
    // Note: State updates happen automatically via streaming - no manual state management needed!

    private func addTodo(title: String) async {
        print("[TodoListView] addTodo called with title: '\(title)'")
        print("[TodoListView] $state.actor = \($state.actor != nil ? "resolved" : "nil")")

        guard let todoList = $state.actor else {
            print("[TodoListView] Guard failed: actor is nil")
            return
        }

        do {
            print("[TodoListView] Calling todoList.addTodo...")
            let result = try await todoList.addTodo(title: title)
            print("[TodoListView] addTodo returned: \(result)")
            // State automatically updates via stream - no manual todos.append needed!
        } catch {
            print("[TodoListView] Error adding todo: \(error)")
        }
    }

    private func toggleTodo(id: UUID) async {
        guard let todoList = $state.actor else { return }

        do {
            _ = try await todoList.toggleTodo(id: id)
            // State automatically updates via stream - no manual todos update needed!
        } catch {
            print("Error toggling todo: \(error)")
        }
    }

    private func deleteTodo(id: UUID) async {
        guard let todoList = $state.actor else { return }

        do {
            _ = try await todoList.deleteTodo(id: id)
            // State automatically updates via stream - no manual todos.removeAll needed!
        } catch {
            print("Error deleting todo: \(error)")
        }
    }

    private func clearCompleted() async {
        guard let todoList = $state.actor else { return }

        do {
            _ = try await todoList.clearCompleted()
            // State automatically updates via stream - no manual todos.removeAll needed!
        } catch {
            print("Error clearing completed: \(error)")
        }
    }
}

#Preview {
    TodoListView()
        .Trebuchet(transport: .webSocket(host: "127.0.0.1", port: 8080))
}
