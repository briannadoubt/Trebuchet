//
//  TodoRowView.swift
//  TrebuchetDemo
//
//  Created by Brianna Zamora on 1/20/26.
//

import SwiftUI
import Shared

struct TodoRowView: View {
    let todo: TodoItem
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Completion toggle
            Button(action: onToggle) {
                Image(systemName: todo.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(todo.isCompleted ? .green : .secondary)
            }
            .buttonStyle(.plain)

            // Title
            VStack(alignment: .leading, spacing: 2) {
                Text(todo.title)
                    .strikethrough(todo.isCompleted)
                    .foregroundStyle(todo.isCompleted ? .secondary : .primary)

                Text(todo.createdAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button(action: onToggle) {
                Label(
                    todo.isCompleted ? "Mark Incomplete" : "Mark Complete",
                    systemImage: todo.isCompleted ? "arrow.uturn.backward" : "checkmark"
                )
            }
            .tint(todo.isCompleted ? .orange : .green)
        }
    }
}

#Preview {
    List {
        TodoRowView(
            todo: TodoItem(title: "Buy groceries"),
            onToggle: {},
            onDelete: {}
        )
        TodoRowView(
            todo: TodoItem(title: "Walk the dog", isCompleted: true),
            onToggle: {},
            onDelete: {}
        )
    }
}
