import SwiftUI

/// A nicer notes editor: write Markdown with a quick-format bar, then flip to a
/// rendered preview. Scales with the global text-size setting.
struct NotesEditor: View {
    @Binding var text: String
    var minHeight: CGFloat = 160
    var onChange: () -> Void = {}

    @State private var preview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: Theme.Space.sm) {
                if !preview { formatBar }
                Spacer()
                Picker("", selection: $preview) {
                    Image(systemName: "pencil").tag(false)
                    Image(systemName: "eye").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .labelsHidden()
            }

            if preview {
                Group {
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Nothing to preview yet.").foregroundStyle(Theme.textSecondary)
                    } else {
                        MarkdownView(markdown: text)
                    }
                }
                .frame(minHeight: minHeight, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            } else {
                TextEditor(text: $text)
                    .font(.system(size: 14 * Appearance.shared.fontScale))
                    .frame(minHeight: minHeight)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                    .onChange(of: text) { _, _ in onChange() }
            }
        }
    }

    private var formatBar: some View {
        HStack(spacing: 2) {
            block("number", "## ")
            block("list.bullet", "- ")
            block("checklist", "- [ ] ")
            block("text.quote", "> ")
            inlineWrap("bold", "**")
            inlineWrap("italic", "*")
        }
        .foregroundStyle(Theme.textSecondary)
        .font(.system(.body))
    }

    private func block(_ icon: String, _ prefix: String) -> some View {
        Button { startLine(prefix) } label: { Image(systemName: icon).frame(width: 24, height: 22) }
            .buttonStyle(.plain)
    }

    private func inlineWrap(_ icon: String, _ token: String) -> some View {
        Button { appendInline(token) } label: { Image(systemName: icon).frame(width: 24, height: 22) }
            .buttonStyle(.plain)
    }

    /// Append a new block line beginning with `prefix`. (The TextEditor's own
    /// onChange observer fires the save, so we don't call onChange() here.)
    private func startLine(_ prefix: String) {
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += prefix
    }

    /// Append a wrapped inline placeholder, e.g. **text**.
    private func appendInline(_ token: String) {
        if !text.isEmpty && !text.hasSuffix(" ") && !text.hasSuffix("\n") { text += " " }
        text += "\(token)text\(token)"
    }
}
