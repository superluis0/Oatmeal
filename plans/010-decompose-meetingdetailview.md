# Plan 010: Decompose the `MeetingDetailView` god file (phased, behavior-preserving)

> **Executor instructions**: This is a LARGE, higher-risk refactor. Do it in the
> phases below, building after EVERY phase. Do not attempt the whole thing in one
> pass. STOP and report on any STOP condition. Update `plans/README.md` when done
> (or when you've completed a phase and are handing off).
>
> **Drift check (run first)**: `git diff --stat 23dc9c8..HEAD -- Oatmeal/Views/MeetingDetailView.swift`
> NOTE: this file has UNCOMMITTED changes from a prior session (a deleted-object
> crash fix that added an `isDeleted || modelContext == nil` guard and a
> `scrollContent(proxy:)` helper). Work against the live file; locate everything
> by symbol name, never by the line numbers in this plan.

## Status

- **Priority**: P3
- **Effort**: L
- **Risk**: HIGH
- **Depends on**: plans/001 (REQUIRED — do not refactor this file without a test net)
- **Category**: tech-debt
- **Planned at**: commit `23dc9c8`, 2026-06-14

## Why this matters

`MeetingDetailView.swift` is 1735 lines and mixes ~10 responsibilities:
audio playback, transcript display + speaker rename/merge/re-identify, enhanced
notes, summary/highlights/recurring, action-item re-extraction, recipes,
follow-ups, tabbed navigation, deletion, plus several free-standing helper
structs. `MeetingDetailView` alone carries 23 `@State` vars, so any state change
re-evaluates dozens of computed subviews. It's the file the SwiftData
deleted-object crash class keeps recurring in (the guards live here). Smaller,
focused views are easier to test, review, and keep crash-safe. Because the risk
is real, this plan is **strictly behavior-preserving** and **phased**: the early
phases are near-mechanical file moves; later phases extract cohesive subsystems
one at a time.

## Current state

`MeetingDetailView.swift` contains these TOP-LEVEL types (confirmed at planning):
- `RecordingView` (the live-recording view; ~lines 7-198)
- `MeetingDetailContainer` (resolves a live `Meeting` by id; ~199-227)
- `MeetingDetailView` (the god view; ~228-1153)
- `OatSegmentedTabs` (private; ~1154-1206)
- `MarkdownView` (~1207-1387)
- `ProvenanceNotesView` (~1388-1496)
- `SegmentRow` (~1497-1547)
- `StreamingText` (ViewModifier; ~1548-1565)
- `LiveSuggestionCard` (~1566-end)

Within `MeetingDetailView`, cohesive clusters (by the subviews/funcs that move
together):
- **Transcript subsystem**: `transcriptSection`, `playerBar`,
  `speakerRenameEditor`, `transcriptRow`, `editableRow`, `reidentify()`,
  `mergeSpeaker(_:into:)`, `speakerNameBinding(_:)`, `color(for:)`,
  `loadAudioIfNeeded()`, the `player` state, `editingTranscript`,
  `reidentifySpeakerCount`, `reidentifying`, `jumpTarget`.
- **Enhanced notes**: `enhancedSection`, `enhancingSkeleton`, `provenanceLegend`,
  `enhance()`, `insertIntoNotes(_:)`, `isEnhancing`, `enhanceError`.
- **Summary/highlights/recurring**: `summarySection`, `highlightsSection`,
  `recurringSection`, `seriesMatches(_:)`, `previousOccurrences`,
  `catchMeUp(prior:)`.
- **Recipes/follow-ups**: `runRecipe(_:)`, `followUpSheet`, `reextractActions()`,
  `showRecipes`, `recipeResult`, `recipeIsEmail`, `runningRecipe`,
  `showFollowUpSheet`, `followUpDate`, `reextracting`.

Critical safety invariant to PRESERVE: `MeetingDetailView.body` and
`scrollContent(proxy:)` guard with `meeting.isDeleted || meeting.modelContext
== nil` before reading meeting data. Any extracted child view that reads
`meeting` relationships/attributes must be rendered only under that guard (i.e.
the parent keeps the guard; children are only built when the meeting is live),
or carry its own guard. Do NOT lose this.

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| Build | `xcodebuild -project Oatmeal.xcodeproj -scheme Oatmeal -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/OatmealBuild build` | `** BUILD SUCCEEDED **` |
| Test | `xcodebuild test -project Oatmeal.xcodeproj -scheme Oatmeal -destination 'platform=macOS' -derivedDataPath /tmp/OatmealBuild` | `** TEST SUCCEEDED **` |
| Line count | `wc -l Oatmeal/Views/MeetingDetailView.swift` | shrinks each phase |

Note: new `.swift` files added under `Oatmeal/` are picked up automatically
(XcodeGen globs `path: Oatmeal`), but you MUST run `xcodegen generate` after
adding files before building, OR add them and rebuild via the Xcode project that
already globs the folder — to be safe, run `xcodegen generate` after creating
new files.

## Scope

**In scope**: splitting `Oatmeal/Views/MeetingDetailView.swift` into multiple
files under `Oatmeal/Views/` and extracting child views — WITHOUT changing
behavior, layout, or the data each view reads.

**Out of scope**:
- Any functional change, layout tweak, or restyle (pure structure only).
- Changing the deleted-object guards' logic.
- `RecordingView` and `MeetingDetailContainer` (leave them; they can stay in a
  renamed file or move wholesale, but don't restructure them).
- Introducing a ViewModel/coordinator layer (tempting, but that's a behavior-
  risking architecture change — separate future plan).
- Plans 003/008 edits (if not yet landed, coordinate; don't redo them here).

## Steps

### Phase 1 — Move the free-standing helper types to their own files (mechanical)

These types are already independent structs; moving each to its own file is
near-zero risk and immediately shrinks the god file. For each, cut the type
verbatim into a new file with the same imports (`import SwiftUI`, plus
`SwiftData`/`AppKit` if the type uses them):
- `MarkdownView` + its private helpers (`tableView`, `tableRow`, `lineView`,
  `bulletRow`, `numberedItem`, `inline`) → `Oatmeal/Views/MarkdownView.swift`
- `ProvenanceNotesView` (+ `blockRow`, `sourcesView`, `canGround`, `toggle`) →
  `Oatmeal/Views/ProvenanceNotesView.swift`
- `SegmentRow` → `Oatmeal/Views/SegmentRow.swift`
- `OatSegmentedTabs` → `Oatmeal/Views/OatSegmentedTabs.swift` (keep `private`?
  it's `private struct`; if it's used only within this file, make it `internal`
  when moving so other files can see it — verify usages with
  `grep -rn "OatSegmentedTabs" Oatmeal`).
- `StreamingText` (ViewModifier) → `Oatmeal/Views/StreamingText.swift`
- `LiveSuggestionCard` → `Oatmeal/Views/LiveSuggestionCard.swift`

After each move: `xcodegen generate` (if new file) then build. Fix only access-
level errors (a `private` helper that's actually used cross-type becomes
`internal`); do NOT change logic.

**Verify after Phase 1**: build + tests pass; `wc -l MeetingDetailView.swift`
is materially smaller; `git diff` shows pure moves (no logic deltas).

**This is a natural STOP/handoff point** — if you only complete Phase 1, that's
already a meaningful, safe win. Update the README status to note Phase 1 done.

### Phase 2 — Extract the transcript subsystem into a child view

Create `Oatmeal/Views/MeetingTranscriptSection.swift` with a
`struct MeetingTranscriptSection: View` that takes the inputs it needs
explicitly (e.g. `@Bindable var meeting: Meeting`, the `AudioPlayer`, and any
bindings/callbacks for jump/edit state). Move into it: `transcriptSection`,
`playerBar`, `speakerRenameEditor`, `transcriptRow`, `editableRow`,
`reidentify()`, `mergeSpeaker`, `speakerNameBinding`, `color(for:)`, plus the
transcript-only `@State` (`editingTranscript`, `reidentifySpeakerCount`,
`reidentifying`, `jumpTarget`, and the `player` if it's used only here — if the
player is shared with another section, hoist it to the parent and pass it in).

In `MeetingDetailView`, replace the inlined transcript tab content with
`MeetingTranscriptSection(meeting: meeting, player: player, ...)`. Keep it
rendered only under the existing liveness guard.

Preserve: the `jump(to:)` scroll behavior (the `ScrollViewProxy` interaction)
and the deleted-object guards. If `jump`/`scrollContent` couples transcript
scrolling to the parent's `ScrollViewReader`, keep the proxy in the parent and
pass a closure — do not break the jump-to-segment feature.

**Verify after Phase 2**: build + tests pass; manually (if running) confirm
transcript renders, speaker rename/merge/re-identify work, audio play/seek
work, and jump-to-segment from a note still scrolls + plays.

### Phase 3 (optional, only if time/confidence allow) — extract one more cluster

Pick ONE of {enhanced-notes, summary/recurring} and extract it the same way as
Phase 2 (explicit inputs, render under the guard, no behavior change). Do NOT do
both in one pass. If unsure, STOP after Phase 2 and hand off — partial,
verified progress beats a risky big-bang.

## Test plan

- Plan 001's suite must pass unchanged after every phase (it guards the pure
  logic this refactor shouldn't touch).
- Add no new behavior; therefore no new behavior tests. If you extract a pure
  helper (e.g. `color(for:)` or `seriesMatches`) into a testable location, add a
  small unit test for it.
- Primary verification is build + tests green after each phase, plus the manual
  parity checks listed per phase.

## Done criteria

Minimum (Phase 1) — ALL must hold:
- [ ] The 6 helper types live in their own files under `Oatmeal/Views/`.
- [ ] `MeetingDetailView.swift` line count dropped by roughly the moved types.
- [ ] Build + tests pass; `git diff` for Phase 1 shows pure moves.

Full (Phases 1-2) — additionally:
- [ ] Transcript subsystem is a standalone `MeetingTranscriptSection` view.
- [ ] Deleted-object guards preserved (child rendered only when meeting is live).
- [ ] Manual parity: transcript, speaker ops, audio, jump-to-segment all work.
- [ ] `plans/README.md` status row updated (note which phases completed).

## STOP conditions

Stop and report (do not improvise) if:
- Plan 001 has NOT landed (no test net) — do not start; report the dependency.
- Extracting a cluster would require duplicating or weakening the
  `isDeleted || modelContext == nil` guard — stop and report; the guard's
  integrity outranks the refactor.
- A move changes layout or behavior in any visible way — revert that step.
- The `ScrollViewReader`/`jump(to:)` coupling can't be preserved cleanly when
  extracting the transcript — stop after Phase 1 and report.
- Access-level changes start cascading widely (sign the extraction boundary is
  wrong) — stop and report the dependency tangle.

## Maintenance notes

- After this lands, update `CLAUDE.md` (plan 002) to point at the new file
  layout and reiterate the guard requirement for any view reading `meeting`.
- The remaining clusters (enhanced notes, summary/recurring, recipes/follow-ups)
  are future extraction candidates; each is its own small plan once Phases 1-2
  prove the pattern.
- A ViewModel/coordinator layer (moving `enhance()`, `runRecipe()`,
  `reextractActions()` off the view) is the logical next step but is a behavior-
  risking change — keep it separate and test-guarded.
- Reviewer: scrutinize that NOTHING but file location and access levels changed
  in Phase 1, and that Phase 2 preserved the guards and the jump feature.
