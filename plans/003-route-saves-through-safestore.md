# Plan 003: Route all SwiftData saves through `SafeStore.save`

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. If a
> STOP condition occurs, stop and report. Update `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat 23dc9c8..HEAD -- Oatmeal/Model/SafeStore.swift Oatmeal/Views Oatmeal/Search Oatmeal/Integrations`
> NOTE: the working tree may already contain uncommitted changes in
> `MeetingDetailView.swift`, `MeetingListView.swift`, `ContentView.swift`
> (a HUD/crash-fix session). Re-confirm each `try? context.save()` site with the
> grep in Step 1 before editing — do not rely on line numbers in this plan.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: plans/001 (recommended — gives a regression net), not hard-required
- **Category**: bug
- **Planned at**: commit `23dc9c8`, 2026-06-14

## Why this matters

The codebase has a purpose-built `SafeStore.save` that catches the Objective-C
exceptions SwiftData/CoreData raise (e.g. saving a relationship to a deleted
row) — exceptions that `try? context.save()` **cannot** catch and which abort
the whole app. Yet there are **40 raw `try? save` calls** versus only 14
`SafeStore.save` calls. Two distinct harms: (1) a raw save that throws an ObjC
exception crashes instead of rolling back (the exact crash class the git
history keeps fixing); (2) a raw `try?` silently swallows ordinary save errors,
so user edits (title, tags, notes, transcript) can vanish on relaunch with no
feedback. This plan makes `SafeStore.save` the single save path.

## Current state

`Oatmeal/Model/SafeStore.swift` (the intended path):

```swift
@MainActor
enum SafeStore {
    @discardableResult
    static func save(_ context: ModelContext, _ context_label: String = "") -> Bool {
        var swiftError: Error?
        let exception = ExceptionCatcher.catch {
            do { try context.save() } catch { swiftError = error }
        }
        if let exception {
            Log.error("save raised an exception (\(context_label)): \(exception.name.rawValue) — \(exception.reason ?? "")", "store")
            ExceptionCatcher.catch { context.rollback() }
            return false
        }
        if let swiftError {
            Log.error("save failed (\(context_label))", "store", swiftError)
            return false
        }
        return true
    }
}
```

Raw `try? context.save()` / `try? modelContext.save()` currently appear in
these files (confirmed by grep at planning time):
`Oatmeal/Search/SemanticIndex.swift`, `Oatmeal/Views/SettingsView.swift`,
`Oatmeal/Views/RecipesView.swift`, `Oatmeal/Views/MeetingDetailView.swift`,
`Oatmeal/Views/AnalyticsView.swift`, `Oatmeal/Views/MeetingTriageView.swift`,
`Oatmeal/Views/GlobalChatView.swift`, `Oatmeal/Views/PreMeetingBriefView.swift`,
`Oatmeal/Views/TasksView.swift`, `Oatmeal/Views/MeetingListView.swift`,
`Oatmeal/Views/TemplateEditorView.swift`.

Example (from `MeetingDetailView` `addTag()`):
```swift
meeting.tags.append(tag)
try? context.save()
```
Target shape:
```swift
meeting.tags.append(tag)
SafeStore.save(context, "add-tag")
```

`SafeStore` is `@MainActor`; all the call sites above are SwiftUI views / view
helpers already on the main actor, so no isolation change is needed. Each call
site has a `context` (or `modelContext`) in scope — verify per site.

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| Find every raw save | `grep -rn "try? context.save()\|try? modelContext.save()" Oatmeal --include="*.swift"` | the working list |
| Build | `xcodebuild -project Oatmeal.xcodeproj -scheme Oatmeal -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/OatmealBuild build` | `** BUILD SUCCEEDED **` |
| Confirm none remain | `grep -rn "try? context.save()\|try? modelContext.save()" Oatmeal --include="*.swift"` | no output |

## Scope

**In scope** (modify): the 11 files listed above — replace each raw
`try? context.save()` / `try? modelContext.save()` with
`SafeStore.save(context, "<short-label>")` using a label that names the action.

**Out of scope** (do NOT touch):
- `Oatmeal/Model/SafeStore.swift` itself.
- `try? context.fetch(...)` and other non-save `try?` calls — only saves.
- `Oatmeal/Model/StoreBackup.swift` (`do/try/catch` already; leave it).
- `RecordingCoordinator.swift` (already uses `SafeStore.save`).
- Any change to WHEN a save happens — only HOW (swap the call, same location).

## Git workflow

- Branch: `advisor/003-route-saves-through-safestore`
- Commit per file or in small batches; subject e.g. "Route saves through SafeStore in TasksView".

## Steps

### Step 1: Enumerate the call sites

Run the grep above and capture the full list (file:line). Work the list
top to bottom. For each site, read ~5 lines of surrounding context to choose a
descriptive label (e.g. `"toggle-task-done"`, `"rename-speaker"`,
`"save-settings"`).

**Verify**: you have a checklist of every site.

### Step 2: Replace each raw save

For each site, replace `try? context.save()` with
`SafeStore.save(context, "<label>")` (or `modelContext` → still pass the
in-scope context variable). `SafeStore.save` is `@discardableResult`, so a
bare statement compiles. Do not add `if !SafeStore.save(...)` error UI in this
plan — that's a follow-up; the immediate win is crash-safety + logging.

Confirm `context`/`modelContext` is the variable in scope at each site; if a
site uses a differently named context, pass that variable.

**Verify** after each batch: build command → `** BUILD SUCCEEDED **`.

### Step 3: Confirm completeness

Run the "Confirm none remain" grep. Expect **no output**. If a site can't be
converted (e.g. not on the main actor — unlikely in views), STOP and report it
rather than forcing it.

**Verify**: grep returns nothing; build still succeeds.

## Test plan

- This is a mechanical safety swap; behavior on the happy path is unchanged
  (save still happens), so no new unit tests are strictly required.
- If plan 001 has landed, add one test asserting `SafeStore.save` returns
  `true` for a trivial successful save on an in-memory `ModelContainer`
  (documents the contract). Optional but recommended.
- Verification is the build + the "no raw saves remain" grep.

## Done criteria

ALL must hold:
- [ ] `grep -rn "try? context.save()\|try? modelContext.save()" Oatmeal --include="*.swift"` returns no output.
- [ ] Build succeeds (`** BUILD SUCCEEDED **`).
- [ ] `git diff` shows only call-site swaps (no logic/timing changes, no out-of-scope files).
- [ ] `plans/README.md` status row updated.

## STOP conditions

Stop and report if:
- A call site is NOT on the main actor (SafeStore is `@MainActor`) — needs a
  different approach; report which site.
- A site's surrounding code shows the save is intentionally fire-and-forget in
  a context where logging would be noisy (rare) — flag rather than guess.
- The build breaks and the cause isn't an obvious missing `context` variable.

## Maintenance notes

- Follow-up (not in this plan): surface a user-visible toast when
  `SafeStore.save` returns `false` on user-initiated edits (notes/title/tags),
  so silent failures become visible. Track separately.
- Reviewer should confirm no save site changed its timing or call location —
  only the function called.
- After this lands, update `CLAUDE.md` (plan 002) to state raw saves are now
  forbidden and `SafeStore.save` is mandatory.
