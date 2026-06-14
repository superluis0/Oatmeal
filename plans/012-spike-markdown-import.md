# Plan 012 (SPIKE): Design a Markdown importer to close the export→edit→import loop

> **Executor instructions**: DESIGN/SPIKE plan. Deliverable is a design doc +
> a pure parser prototype with tests, NOT a shipped import feature with UI.
> Update `plans/README.md` when delivered.

## Status

- **Priority**: P3 (direction)
- **Effort**: M (spike), M-L (implementation)
- **Risk**: MED — merge/conflict semantics can lose user edits if done naively
- **Depends on**: plans/001 (so the parser ships with tests)
- **Category**: direction
- **Planned at**: commit `23dc9c8`, 2026-06-14

## Why this matters

`MarkdownExporter` exports meetings (files, clipboard, PDF, and an Obsidian
vault with YAML frontmatter), but there is no importer — a user can export and
edit a meeting in Markdown but can't bring edits back. The export already emits
structured frontmatter, so the parsing half is well-defined; the risk and the
real design work is the **merge** decision.

## Current state

`Oatmeal/Export/MarkdownExporter.swift` emits YAML frontmatter:
```swift
var fm = "---\n"
fm += "title: \"\(yaml(meeting.title))\"\n"
fm += "date: \(ISO8601DateFormatter().string(from: meeting.date))\n"
// attendees, tags also emitted as quoted YAML lists
fm += "---\n\n"
```
and a `yaml(_:)` escaper. `exportVault(_:)` writes one file per meeting.
`AudioImporter` exists (audio in), but there is no Markdown/notes importer.

## Scope (of the spike)

**In scope**: `docs/design/markdown-import.md`; a PURE parser
`MarkdownImporter.parse(_ text: String) -> ParsedMeeting?` (frontmatter +
body → title/date/attendees/tags/notes) with unit tests against the exporter's
own output; a written merge-strategy recommendation.

**Out of scope**: import UI, file pickers, actually creating/merging `Meeting`
records in the live store, transcript re-import (decide in the doc whether
transcript is even importable).

## Steps

1. **Round-trip study.** Export a sample meeting (read `MarkdownExporter` to know
   the exact emitted shape). Document the precise frontmatter keys + body layout
   the importer must accept.
2. **Pure parser prototype.** Implement `MarkdownImporter.parse` (no SwiftData,
   no IO) returning a plain `ParsedMeeting` struct. Parse the `---` frontmatter
   block (title, date via `ISO8601DateFormatter`, attendees/tags lists) and the
   notes body. Be lenient about hand-edits (extra whitespace, missing optional
   keys).
3. **Tests.** Unit-test the parser against `MarkdownExporter`'s output for a
   fixture meeting (round-trip: export shape in → expected fields out), plus
   malformed inputs (no frontmatter, missing keys, junk) → graceful nil/partial.
4. **Merge-strategy doc.** This is the crux: when importing an edited file for an
   existing meeting (matched by id/title+date), what happens? Evaluate:
   create-new-only (safe, no data loss), overwrite-notes (simple, risky),
   field-level merge (complex). Recommend one; list the data-loss risks of each.
5. **Open questions** (match key: frontmatter id vs title+date? what if no match?
   is transcript ever overwritten? Obsidian-edit workflow expectations?).

**Verify**: `docs/design/markdown-import.md` exists; the parser + its tests run
green (`xcodebuild test`); no live-store code added.

## Done criteria

- [ ] Pure `MarkdownImporter.parse` prototype with passing unit tests against the
      exporter's real output and malformed inputs.
- [ ] Design doc covering the parse contract + a recommended merge strategy with
      explicit data-loss analysis + open questions.
- [ ] No import UI and no live-store mutation shipped.
- [ ] `plans/README.md` updated.

## STOP conditions

- If the exporter's output isn't actually round-trippable (e.g. lossy formatting
  that can't be parsed back) — document the gap and stop; that's a finding for
  the maintainer.
- If merge semantics can't be made safe without product decisions — stop at the
  doc; do not pick a lossy default and build it.

## Maintenance notes

- Implementation should default to the least-surprising, no-data-loss merge
  (likely create-new or explicit user confirmation before overwrite).
- Keep the parser pure so it stays unit-tested; isolate IO/store in a thin layer.
