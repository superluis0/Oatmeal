# Plan 009: Track and cancel Live-Assist suggestion tasks on stop

> **Executor instructions**: Follow step by step; verify the build. STOP on any
> STOP condition. Update `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat 23dc9c8..HEAD -- Oatmeal/Coordinator/RecordingCoordinator.swift`

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `23dc9c8`, 2026-06-14

## Why this matters

`maybeAutoAssist()` and `requestSuggestion()` spawn unstructured
`Task { await generateSuggestion(...) }` work, but `stop(context:)` cancels only
`liveTask` — not these suggestion tasks. If a suggestion is in flight when the
user stops recording, it keeps running and can insert a now-stale suggestion
into `liveSuggestions` after the session ended. It isn't a crash today (the
array is cleared on the next recording), but it's a latent foot-gun: it does
work that should be cancelled, and a future change that reads meeting state
inside `generateSuggestion` post-stop could turn this into a real bug. Tracking
and cancelling these tasks makes lifecycle handling correct and consistent with
how `liveTask` is already managed.

## Current state

`Oatmeal/Coordinator/RecordingCoordinator.swift` — `maybeAutoAssist()` spawns
an untracked task:
```swift
private func maybeAutoAssist() {
    guard AppSettings.liveAssistEnabled, !isSuggesting else { return }
    guard let question = Self.latestQuestion(in: liveOthers), question != lastAssistQuestion else { return }
    if let last = lastAssistFire, Date().timeIntervalSince(last) < Self.assistCooldown { return }
    lastAssistQuestion = question
    lastAssistFire = Date()
    Task { await generateSuggestion(question: question) }     // <-- untracked
}
```

`stop(context:)` cancels `liveTask` but not suggestion tasks:
```swift
func stop(context: ModelContext) async {
    guard isRecording else { return }
    Log.info("recording stop requested", "recording")
    liveTask?.cancel()
    liveTask = nil
    timer?.invalidate()
    timer = nil
    ...
}
```

`generateSuggestion(question:)` sets `isSuggesting`, calls
`LiveAssistService().suggest(...)`, and inserts into `liveSuggestions`:
```swift
private func generateSuggestion(question: String?) async {
    guard !isSuggesting else { return }
    isSuggesting = true
    defer { isSuggesting = false }
    let transcript = recentAssistTranscript()
    let profile = AppSettings.assistProfile
    guard let suggestion = try? await LiveAssistService()
        .suggest(question: question, recentTranscript: transcript, profile: profile),
          !suggestion.isEmpty else { return }
    liveSuggestions.insert(suggestion, at: 0)
    if liveSuggestions.count > 8 { liveSuggestions.removeLast() }
}
```

The coordinator is `@MainActor` (`liveTask` and the other `@State`-like
properties are actor-isolated). Find `liveTask`'s declaration (search
`private var liveTask`) to mirror its declaration style for the new property.

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| Build | `xcodebuild -project Oatmeal.xcodeproj -scheme Oatmeal -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/OatmealBuild build` | `** BUILD SUCCEEDED **` |
| Locate sites | `grep -n "liveTask\|generateSuggestion\|maybeAutoAssist\|func stop" Oatmeal/Coordinator/RecordingCoordinator.swift` | the edit sites |

## Scope

**In scope** (modify): `Oatmeal/Coordinator/RecordingCoordinator.swift` only.

**Out of scope**:
- `requestSuggestion()` semantics when NOT recording (the "Suggest now" button
  may be used in contexts you shouldn't break) — see Step 2; only cancel on stop,
  don't forbid suggestions.
- `LiveAssistService` internals.
- The `isSuggesting` guard logic.

## Steps

### Step 1: Track suggestion tasks

Add a property next to `liveTask`:
```swift
private var assistTasks: [Task<Void, Never>] = []
```
In `maybeAutoAssist()`, replace the fire-and-forget with a tracked task and a
light cleanup of finished entries:
```swift
let task = Task { await generateSuggestion(question: question) }
assistTasks.append(task)
assistTasks.removeAll { $0.isCancelled }
```
(Optional: prune completed tasks too, but `isCancelled` pruning plus the cancel
in Step 2 is sufficient; the array is tiny.)

If `requestSuggestion()` also spawns/awaits suggestion work, leave its inline
`await generateSuggestion(...)` as-is (it's structured/awaited by the caller),
OR if you prefer symmetry, wrap it the same way — but keep its current
await-and-return behavior for the button. Do not change its return type.

**Verify**: build → `** BUILD SUCCEEDED **`.

### Step 2: Cancel them in `stop`

In `stop(context:)`, alongside the existing `liveTask?.cancel()`:
```swift
liveTask?.cancel()
liveTask = nil
assistTasks.forEach { $0.cancel() }
assistTasks.removeAll()
```

`generateSuggestion` already guards its result behind `try?` and only mutates
`liveSuggestions` at the end; cancellation will either stop the awaited network
call or the post-await insert becomes a no-op against an array that's cleared on
the next session. (Optional hardening: add `if Task.isCancelled { return }`
right before the `liveSuggestions.insert` so a late completion can't append a
stale suggestion. Recommended.)

**Verify**: build → `** BUILD SUCCEEDED **`.

## Test plan

- This is concurrency-lifecycle; no clean unit test without a fake
  `LiveAssistService`. If a seam is cheap to add (inject a closure that simulates
  a slow suggestion), a test could assert that after `stop()`, a late-completing
  suggestion is not inserted. Otherwise rely on build + reasoning.
- Manual (if running): start recording, trigger a suggestion, immediately stop;
  confirm no suggestion pops in after stop.

## Done criteria

ALL must hold:
- [ ] `assistTasks` is declared, populated in `maybeAutoAssist`, and cancelled +
      cleared in `stop`.
- [ ] (Recommended) `generateSuggestion` early-returns if `Task.isCancelled`
      before mutating `liveSuggestions`.
- [ ] Build succeeds.
- [ ] No change to `requestSuggestion`'s signature/return behavior.
- [ ] `plans/README.md` status row updated.

## STOP conditions

Stop and report if:
- `liveTask` is declared in a way that suggests a different concurrency model
  than plain `Task` (e.g. a `TaskGroup`) — adapt and report.
- Cancelling suggestion tasks interferes with the "Suggest now" button flow
  (it shouldn't, since stop ends the session) — report if it does.

## Maintenance notes

- If suggestion generation ever starts reading live meeting/segment state, the
  `Task.isCancelled` guard before mutation becomes important, not just optional.
- Keep this consistent with `liveTask` handling — if `liveTask` management
  changes, mirror it for `assistTasks`.
