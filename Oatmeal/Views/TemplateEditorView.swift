import SwiftUI
import SwiftData

struct TemplateEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \CustomTemplate.createdAt) private var templates: [CustomTemplate]

    @State private var selected: CustomTemplate?
    @State private var name = ""
    @State private var systemPrompt = ""
    @State private var skeleton = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Templates").font(.headline)
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
        .frame(width: 640, height: 460)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selected) {
                Section("Built-in") {
                    ForEach(NoteTemplate.builtins) { t in
                        Text(t.name)
                            .foregroundStyle(.secondary)
                            .contextMenu {
                                Button {
                                    duplicate(t)
                                } label: { Label("Duplicate to edit", systemImage: "plus.square.on.square") }
                            }
                    }
                }
                Section("Custom") {
                    ForEach(templates) { t in
                        Text(t.name)
                            .tag(t)
                            .contextMenu {
                                Button(role: .destructive) { deleteTemplate(t) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                    .onDelete(perform: deleteTemplates)
                }
            }
            Divider()
            Button {
                createTemplate()
            } label: {
                Label("New Template", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .padding(8)
        }
        .frame(width: 220)
        .onChange(of: selected) { _, new in loadFields(from: new) }
    }

    @ViewBuilder
    private var editor: some View {
        if selected == nil {
            ContentUnavailableView("No Template Selected",
                                   systemImage: "doc.text",
                                   description: Text("Create a new template or pick a custom one to edit."))
                .frame(maxWidth: .infinity)
        } else {
            Form {
                TextField("Name", text: $name)
                    .onChange(of: name) { _, _ in persist() }
                Section("System prompt") {
                    TextEditor(text: $systemPrompt)
                        .frame(minHeight: 80)
                        .onChange(of: systemPrompt) { _, _ in persist() }
                }
                Section("Markdown skeleton (section headings)") {
                    TextEditor(text: $skeleton)
                        .frame(minHeight: 120)
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: skeleton) { _, _ in persist() }
                }
                Section {
                    Button(role: .destructive) {
                        if let t = selected { deleteTemplate(t) }
                    } label: {
                        Label("Delete Template", systemImage: "trash")
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity)
        }
    }

    private func loadFields(from t: CustomTemplate?) {
        name = t?.name ?? ""
        systemPrompt = t?.systemPrompt ?? ""
        skeleton = t?.skeleton ?? ""
    }

    private func createTemplate() {
        let t = CustomTemplate(
            name: "New Template",
            systemPrompt: "Produce clear, well-organized notes for this meeting.",
            skeleton: "## Overview\n## Discussion\n## Action Items"
        )
        context.insert(t)
        try? context.save()
        selected = t
        loadFields(from: t)
    }

    private func persist() {
        guard let t = selected else { return }
        t.name = name
        t.systemPrompt = systemPrompt
        t.skeleton = skeleton
        SafeStore.saveSoon(context, "template-edit")
    }

    private func deleteTemplates(at offsets: IndexSet) {
        for index in offsets { deleteTemplate(templates[index]) }
    }

    private func deleteTemplate(_ t: CustomTemplate) {
        if selected?.persistentModelID == t.persistentModelID { selected = nil }
        context.delete(t)
        try? context.save()
    }

    /// Copy a built-in template into an editable custom one.
    private func duplicate(_ t: NoteTemplate) {
        let copy = CustomTemplate(name: "\(t.name) (copy)", systemPrompt: t.systemPrompt, skeleton: t.skeleton)
        context.insert(copy)
        try? context.save()
        selected = copy
        loadFields(from: copy)
    }
}
