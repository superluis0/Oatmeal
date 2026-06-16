import SwiftUI
import SwiftData

/// Manage custom recipes (reusable prompts).
struct RecipesView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Recipe.createdAt) private var recipes: [Recipe]

    @State private var selected: Recipe?
    @State private var name = ""
    @State private var prompt = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Recipes").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
            Divider()
            HStack(spacing: 0) {
                sidebar
                Divider()
                editor
            }
        }
        .frame(width: 600, height: 420)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selected) {
                Section("Built-in") {
                    ForEach(RecipeProvider.builtins) { r in
                        Text(r.name)
                            .foregroundStyle(.secondary)
                            .contextMenu {
                                Button {
                                    duplicate(r)
                                } label: { Label("Duplicate to edit", systemImage: "plus.square.on.square") }
                            }
                    }
                }
                Section("Custom") {
                    ForEach(recipes) { r in
                        Text(r.name)
                            .tag(r)
                            .contextMenu {
                                Button(role: .destructive) { deleteRecipe(r) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                    .onDelete(perform: delete)
                }
            }
            Divider()
            Button {
                create()
            } label: {
                Label("New Recipe", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .padding(8)
        }
        .frame(width: 200)
        .onChange(of: selected) { _, new in
            name = new?.name ?? ""
            prompt = new?.prompt ?? ""
        }
    }

    @ViewBuilder
    private var editor: some View {
        if selected == nil {
            OatEmptyState(
                icon: "wand.and.stars.inverse",
                title: "No recipe selected",
                message: "Create or pick a custom recipe to edit its prompt."
            )
            .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 0) {
                Form {
                    TextField("Name", text: $name)
                        .onChange(of: name) { _, _ in persist() }
                    Section("Prompt") {
                        TextEditor(text: $prompt)
                            .frame(minHeight: 160)
                            .onChange(of: prompt) { _, _ in persist() }
                    }
                }
                .formStyle(.grouped)
                Divider()
                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        if let r = selected { deleteRecipe(r) }
                    } label: {
                        Label("Delete Recipe", systemImage: "trash")
                    }
                }
                .padding(8)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func create() {
        let r = Recipe(name: "New Recipe", prompt: "Summarize this meeting in three sentences.")
        context.insert(r)
        try? context.save()
        selected = r
    }

    private func persist() {
        guard let r = selected else { return }
        r.name = name
        r.prompt = prompt
        SafeStore.saveSoon(context, "recipe-edit")
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets { deleteRecipe(recipes[index]) }
    }

    private func deleteRecipe(_ r: Recipe) {
        if selected?.persistentModelID == r.persistentModelID { selected = nil }
        context.delete(r)
        try? context.save()
    }

    /// Copy a built-in recipe into an editable custom recipe.
    private func duplicate(_ item: RecipeItem) {
        let r = Recipe(name: "\(item.name) (copy)", prompt: item.prompt)
        context.insert(r)
        try? context.save()
        selected = r
    }
}

/// Shows a recipe's output with copy / mail / insert actions.
struct RecipeResultView: View {
    let text: String
    let isEmail: Bool
    let recipientEmails: [String]
    let onInsert: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Result").font(.headline)
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding()
            Divider()
            ScrollView {
                MarkdownView(markdown: text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            Divider()
            HStack {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: { Label("Copy", systemImage: "doc.on.doc") }
                if isEmail {
                    Button {
                        openInMail()
                    } label: { Label("Open in Mail", systemImage: "envelope") }
                }
                Spacer()
                Button {
                    onInsert()
                    dismiss()
                } label: { Label("Insert into Notes", systemImage: "text.append") }
            }
            .padding()
        }
        .frame(width: 560, height: 460)
    }

    private func openInMail() {
        var subject = "Meeting follow-up"
        var body = text
        if let firstLine = text.components(separatedBy: "\n").first,
           firstLine.lowercased().hasPrefix("subject:") {
            subject = String(firstLine.dropFirst("subject:".count)).trimmingCharacters(in: .whitespaces)
            body = text.components(separatedBy: "\n").dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let to = recipientEmails.joined(separator: ",")
        var comps = URLComponents()
        comps.scheme = "mailto"
        comps.path = to
        comps.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body)
        ]
        if let url = comps.url {
            NSWorkspace.shared.open(url)
        }
    }
}
