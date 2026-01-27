//
//  AddTodoView.swift
//  TrebuchetDemo
//
//  Created by Brianna Zamora on 1/20/26.
//

import SwiftUI

struct AddTodoView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @FocusState private var isFocused: Bool

    let onAdd: (String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What needs to be done?", text: $title)
                        .focused($isFocused)
                        .submitLabel(.done)
                        .onSubmit(addTodo)
                }
            }
            .navigationTitle("New Todo")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addTodo()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                isFocused = true
            }
        }
    }

    private func addTodo() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        onAdd(trimmed)
        dismiss()
    }
}

#Preview {
    AddTodoView { title in
        print("Added: \(title)")
    }
}
