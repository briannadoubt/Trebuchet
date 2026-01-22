//
//  TodoListView.swift
//  TrebucheDemo
//
//  Created by Brianna Zamora on 1/20/26.
//

import SwiftUI
import Trebuche
import Shared

struct TodoListView: View {
    /// The remote TodoList actor - automatically resolved via Trebuche
    @RemoteActor(id: "todos") var todoList: TodoList?

    /// Local state for the list of todos
    @State private var todos: [TodoItem] = []

    /// State for showing the add todo sheet
    @State private var showingAddTodo = false

    /// Loading state
    @State private var isLoading = true

    /// Error message
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                switch $todoList.state {
                case .loading:
                    ProgressView("Connecting...")

                case .disconnected:
                    ContentUnavailableView(
                        "Disconnected",
                        systemImage: "wifi.slash",
                        description: Text("Unable to connect to the server")
                    )

                case .failed(let error):
                    ContentUnavailableView(
                        "Error",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error.localizedDescription)
                    )

                case .resolved:
                    todoListContent
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
                    .disabled(todoList == nil)
                }

                ToolbarItem(placement: .secondaryAction) {
                    Button("Clear Completed") {
                        Task { await clearCompleted() }
                    }
                    .disabled(todos.filter(\.isCompleted).isEmpty)
                }
            }
            .sheet(isPresented: $showingAddTodo) {
                AddTodoView { title in
                    Task { await addTodo(title: title) }
                }
            }
            .refreshable {
                await loadTodos()
            }
        }
    }

    @ViewBuilder
    private var todoListContent: some View {
        if isLoading {
            ProgressView("Loading todos...")
        } else if todos.isEmpty {
            ContentUnavailableView(
                "No Todos",
                systemImage: "checklist",
                description: Text("Tap + to add your first todo")
            )
        } else {
            List {
                ForEach(todos) { todo in
                    TodoRowView(
                        todo: todo,
                        onToggle: { Task { await toggleTodo(id: todo.id) } },
                        onDelete: { Task { await deleteTodo(id: todo.id) } }
                    )
                }
            }
            #if !os(macOS)
            .listStyle(.insetGrouped)
            #endif
        }
    }

    // MARK: - Actions

    private func loadTodos() async {
        guard let todoList else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            todos = try await todoList.getTodos()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addTodo(title: String) async {
        guard let todoList else { return }

        do {
            let newTodo = try await todoList.addTodo(title: title)
            todos.append(newTodo)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func toggleTodo(id: UUID) async {
        guard let todoList else { return }

        do {
            if let updated = try await todoList.toggleTodo(id: id),
               let index = todos.firstIndex(where: { $0.id == id }) {
                todos[index] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteTodo(id: UUID) async {
        guard let todoList else { return }

        do {
            if try await todoList.deleteTodo(id: id) {
                todos.removeAll { $0.id == id }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearCompleted() async {
        guard let todoList else { return }

        do {
            _ = try await todoList.clearCompleted()
            todos.removeAll { $0.isCompleted }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    TodoListView()
        .trebuche(transport: .webSocket(host: "127.0.0.1", port: 8080))
}
