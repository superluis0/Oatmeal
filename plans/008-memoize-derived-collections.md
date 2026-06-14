# Plan 008: Memoize per-render derived collections in the heavy list views

> **Executor instructions**: Follow step by step; verify each build. STOP on any
> STOP condition. Update `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat 23dc9c8..HEAD -- Oatmeal/Views/MeetingListView.swift Oatmeal/Views/PeopleView.swift Oatmeal/Views/TasksView.swift Oatmeal/Views/MeetingDetailView.swift`
> NOTE: `MeetingListView.swift` and `MeetingDetailView.swift` have uncommitted
> changes from a prior session — re-locate each cited computed property by name
> (not line number) before editing.

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: MED
- **Depends on**: plans/001 (recommended for a regression net)
- **Category**: perf
- **Planned at**: commit `23dc9c8`, 2026-06-14

## Why this matters

Several list/detail views recompute O(n) or O(n×m) derived collections inside
`body` (or a computed property read from `body`) on **every** render. SwiftUI
re-evaluates these on any state change, so scrolling, selection, and toggles do
redundant full scans. At the median library size this is invisible; for a power
user with hundreds of meetings/attendees/tasks it causes visible lag. Each fix
is the same shape: compute once into `@State`, refresh in a `.task(id:)` keyed
to the inputs. This plan addresses the worst offenders.

## Current state

**MeetingListView — folder filtering is O(folders × meetings) per render**
(`MeetingListView.swift`, in `body`):
```swift
ForEach(folders) { folder in
    let items = meetings.filter { $0.folder?.persistentModelID == folder.persistentModelID }
    if !items.isEmpty {
        Section { ForEach(items) { row($0) } } header: { SectionLabel(text: folder.name) }
    }
}
let unfiled = meetings.filter { $0.folder == nil }
```
Also `openTaskCount` (computed property) reduces over all meetings calling
`meeting.openActionItemCount` each render.

**PeopleView — rebuilds the entire person map every render**
(`PeopleView.swift`, computed `people`):
```swift
private var people: [Person] {
    var map: [String: Person] = [:]
    for m in meetings { for a in m.liveAttendees { ... } }
    return map.values.sorted { ... }
}
```

**MeetingDetailView — `previousOccurrences`** filters+sorts all `allMeetings`
every time `recurringSection` renders (search for `previousOccurrences`).

**TasksView — `items(in:)`** filters+sorts `filtered` once per bucket
(search for `func items(in` / `filtered`).

Convention for memoization in SwiftUI here: add `@State private var cachedX`,
and a `.task(id: <inputs>) { cachedX = computeX() }` (or `.onChange`).
`@Query`-backed arrays are `Equatable` by identity content; key the `.task` on
the array or a cheap derived token (e.g. `meetings.count` + a hash) — see
STOP conditions for the keying caveat.

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| Build | `xcodebuild -project Oatmeal.xcodeproj -scheme Oatmeal -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/OatmealBuild build` | `** BUILD SUCCEEDED **` |
| Locate props | `grep -rn "previousOccurrences\|func items(in\|private var people\|openTaskCount\|\\.filter { \\$0.folder" Oatmeal/Views` | the edit sites |

## Scope

**In scope** (modify): `MeetingListView.swift`, `PeopleView.swift`,
`TasksView.swift`, `MeetingDetailView.swift` — only the named derived
collections.

**Out of scope**:
- `SemanticIndex.search` linear scan (separate, conditional finding — leave it).
- Any change to displayed data/sort order (must be byte-identical output).
- The god-view decomposition (plan 010) — do not restructure the views here.
- SwiftData fetch/query definitions.

## Steps

Do these ONE view at a time, building and eyeballing after each, so a
regression is easy to localize.

### Step 1: MeetingListView folder grouping

Replace the inline per-folder `.filter` with a single precomputed grouping.
Add a computed helper that builds `[PersistentIdentifier?: [Meeting]]` once:
```swift
private var meetingsByFolder: [PersistentIdentifier?: [Meeting]] {
    Dictionary(grouping: meetings, by: { $0.folder?.persistentModelID })
}
```
Then in `body`: `let grouped = meetingsByFolder` once, and per folder use
`grouped[folder.persistentModelID] ?? []`, and `grouped[nil] ?? []` for unfiled.
(Computing the dictionary once per render is already O(meetings) instead of
O(folders × meetings); promoting to `@State` is optional here since the
dictionary build is single-pass. Prefer the simple single-pass version unless
profiling shows it's still hot.)

**Verify**: build succeeds; sections + unfiled list render identically.

### Step 2: openTaskCount

If `openTaskCount` is shown as a badge, cache it in `@State private var
openTaskCount = 0` and refresh in `.task(id: meetings) { openTaskCount = ... }`,
or accept the single-pass reduce if the count is cheap. Prefer caching only if
`openActionItemCount` itself is non-trivial (it filters `liveActionItems`).

**Verify**: build; badge shows the same number.

### Step 3: PeopleView.people → cached

Convert computed `people` to `@State private var people: [Person] = []`, add a
private `func computePeople() -> [Person]` with the existing body, and refresh
via `.task(id: meetings) { people = computePeople() }`. Ensure the view reads
the state, not the function, in `body`.

**Verify**: build; People list shows the same people in the same order.

### Step 4: MeetingDetailView.previousOccurrences → cached

Convert to `@State private var previousOccurrences: [Meeting] = []` + a
`func computePreviousOccurrences() -> [Meeting]` and refresh in
`.task(id: meeting.persistentModelID) { previousOccurrences = ... }` (and also
re-run when `allMeetings` changes if feasible — see keying caveat). Keep the
`isDeleted`/`modelContext` guards already present in this view; do not read a
dead meeting in the compute.

**Verify**: build; recurring section shows the same occurrences.

### Step 5: TasksView buckets

Precompute `Dictionary(grouping: filtered, by: TaskDates.bucket(for:))` once per
render (single pass) instead of calling `items(in:)` per bucket, OR cache it in
`@State` keyed on `items` + `ownerFilter` + `showDone`. Prefer the single-pass
grouping for simplicity. Preserve per-bucket sort order.

**Verify**: build; each bucket lists the same tasks in the same order.

## Test plan

- These are view-layer perf changes; output must be identical. There's no clean
  unit test for SwiftUI body output. If a derived computation is extracted into
  a pure free function/static (e.g. a `peopleFrom(meetings:)`), add a unit test
  asserting it equals the old result for a fixture set.
- Primary verification: build + manual parity check of each view (same items,
  order, counts).

## Done criteria

ALL must hold:
- [ ] MeetingListView no longer filters `meetings` once per folder per render
      (uses a single grouping).
- [ ] PeopleView and MeetingDetailView.previousOccurrences are cached in
      `@State` and refreshed via `.task(id:)`.
- [ ] TasksView computes buckets in a single pass (or cached).
- [ ] Build succeeds; each view's output is unchanged (manual parity).
- [ ] `plans/README.md` status row updated.

## STOP conditions

Stop and report if:
- **Keying caveat**: `.task(id:)` requires the id be `Equatable`/`Hashable`.
  `[Meeting]` is not trivially a stable id; if keying on the array is awkward,
  key on a cheap token (`meetings.count` plus the max `date`), and note that
  edits that don't change count/maxDate won't refresh until another trigger.
  If you can't find a correct, cheap key for a given view, leave that view as a
  single-pass computed (Steps 1/5 style) and report.
- Any view's output changes (different items/order) — revert that view, report.
- The cached-state approach fights an existing `.onChange`/`.task` in the view.

## Maintenance notes

- If pagination or server-side filtering is ever added to these lists, revisit
  the caching keys.
- The cleanest long-term answer for some of these is moving aggregation into the
  data layer (e.g. a stored `openActionItemCount`), but that's a schema change —
  out of scope here.
- Reviewer should diff rendered output mentally: these must be pure perf changes.
