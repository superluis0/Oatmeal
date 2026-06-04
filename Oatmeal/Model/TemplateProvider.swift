import Foundation
import SwiftData

/// Merges built-in `NoteTemplate`s with user-defined `CustomTemplate`s so every
/// picker and the enhancement pipeline see one unified list.
enum TemplateProvider {
    static func all(context: ModelContext) -> [NoteTemplate] {
        let descriptor = FetchDescriptor<CustomTemplate>(sortBy: [SortDescriptor(\.createdAt)])
        let customs = (try? context.fetch(descriptor)) ?? []
        return NoteTemplate.builtins + customs.map {
            NoteTemplate(name: $0.name, systemPrompt: $0.systemPrompt, skeleton: $0.skeleton)
        }
    }

    static func resolve(name: String?, context: ModelContext) -> NoteTemplate {
        all(context: context).first { $0.name == name } ?? NoteTemplate.general
    }
}
