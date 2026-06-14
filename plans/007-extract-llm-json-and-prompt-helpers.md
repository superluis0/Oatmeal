# Plan 007: Extract a shared LLM JSON-extraction helper (and consolidate prompt assembly)

> **Executor instructions**: Follow step by step; verify each build and the
> tests. STOP on any STOP condition. Update `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat 23dc9c8..HEAD -- Oatmeal/Summary`
> Re-confirm the excerpts in "Current state" against live code before editing.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: plans/001 (the tests target — this plan adds tests)
- **Category**: tech-debt
- **Planned at**: commit `23dc9c8`, 2026-06-14

## Why this matters

The brace/bracket JSON-extraction logic that salvages JSON from a chatty local
LLM is re-implemented in at least three Summary services, and prompt/transcript
assembly is copy-pasted across all of them. A fix to the fragile parser (the
most common real-world failure: the model wraps JSON in prose or ```` ```json ````
fences) currently has to be made in every copy. Consolidating into one tested
helper removes the duplication and gives the parser a single place to harden.
This plan does the **JSON-extraction consolidation** (high value, low risk,
pure functions) and is explicitly conservative about the larger prompt-builder
refactor (see Scope).

## Current state

Duplicated extraction logic (confirmed at planning time):

`Oatmeal/Summary/SummarizationService.swift:134-140`:
```swift
private func extractJSON(from content: String) -> String? {
    guard let start = content.firstIndex(of: "{"),
          let end = content.lastIndex(of: "}"), start < end else {
        return nil
    }
    return String(content[start...end])
}
```

`Oatmeal/Summary/ActionItemExtractor.swift:56-60`:
```swift
private func extractArray(from content: String) -> String? {
    guard let start = content.firstIndex(of: "["),
          let end = content.lastIndex(of: "]"), start < end else { return nil }
    return String(content[start...end])
}
```

`Oatmeal/Summary/LiveAssistService.swift:105-106` (same pattern, inline in its
`parse`):
```swift
guard let start = content.firstIndex(of: "{"),
      let end = content.lastIndex(of: "}"), start < end else { return nil }
```

The shared client already exists and is the right home-adjacent layer:
`Oatmeal/Summary/LMStudioClient.swift` defines `LMStudioMessage` and
`LMStudioClient.chat(messages:temperature:)`. Convention: these services are
plain `struct`s with `async` methods that call `client.chat(...)` then `parse`.

NOTE (from plan 001): if plan 001 landed, `extractJSON` and `extractArray` were
made internal (not private) and have characterization tests in
`OatmealTests/JSONExtractionTests.swift`. Preserve those tests' expectations
(or update them deliberately if you intentionally change behavior).

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| Build | `xcodebuild -project Oatmeal.xcodeproj -scheme Oatmeal -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/OatmealBuild build` | `** BUILD SUCCEEDED **` |
| Test | `xcodebuild test -project Oatmeal.xcodeproj -scheme Oatmeal -destination 'platform=macOS' -derivedDataPath /tmp/OatmealBuild` | `** TEST SUCCEEDED **` |
| Find extractors | `grep -rn "firstIndex(of:\|lastIndex(of:\|extractJSON\|extractArray" Oatmeal/Summary` | the sites to consolidate |

## Scope

**In scope** (create + modify):
- Create `Oatmeal/Summary/LLMJSON.swift` — one small `enum LLMJSON` with two
  static pure functions: `object(in:) -> String?` and `array(in:) -> String?`.
- Modify `SummarizationService.swift`, `ActionItemExtractor.swift`,
  `LiveAssistService.swift` to call `LLMJSON` instead of their local copies.
- Create/extend `OatmealTests/JSONExtractionTests.swift` to target `LLMJSON`.

**Out of scope** (do NOT do in this plan):
- The broader "prompt builder / transcript-truncation DSL" refactor across all 8
  services. It's real debt but higher-risk (it changes prompt *text*, which
  changes LLM output). Capture it as a follow-up in Maintenance notes, don't do
  it here.
- Changing what each service does with the parsed JSON (field mapping, fallbacks).
- `NoteEnhancementService` (returns raw markdown — no JSON parsing; leave it).

## Steps

### Step 1: Create the shared `LLMJSON` helper

`Oatmeal/Summary/LLMJSON.swift`:
```swift
import Foundation

/// Salvages a JSON object/array from a chatty local-LLM response — models often
/// wrap JSON in prose or ```json fences. Pure + synchronous so it's unit-tested.
enum LLMJSON {
    /// First `{` … last `}` (inclusive), or nil if absent/empty.
    static func object(in content: String) -> String? {
        guard let start = content.firstIndex(of: "{"),
              let end = content.lastIndex(of: "}"), start < end else { return nil }
        return String(content[start...end])
    }

    /// First `[` … last `]` (inclusive), or nil if absent/empty.
    static func array(in content: String) -> String? {
        guard let start = content.firstIndex(of: "["),
              let end = content.lastIndex(of: "]"), start < end else { return nil }
        return String(content[start...end])
    }
}
```
This intentionally preserves the EXACT current behavior (first-open/last-close).
Do not "improve" it here — characterization first.

**Verify**: build → `** BUILD SUCCEEDED **`.

### Step 2: Switch the three services to `LLMJSON`

- `SummarizationService`: replace the body of `parse` that calls `extractJSON`
  with `LLMJSON.object(in: content)`; delete the private `extractJSON`.
- `ActionItemExtractor`: replace `extractArray(from:)` call with
  `LLMJSON.array(in: content)`; delete the private `extractArray`.
- `LiveAssistService`: replace the inline `firstIndex/lastIndex` block in its
  `parse` with `LLMJSON.object(in: content)`.

Keep each service's downstream field-mapping/fallback logic unchanged.

**Verify**: build → `** BUILD SUCCEEDED **`; grep "extractJSON\|extractArray"
returns no definitions (only, if anything, none).

### Step 3: Point the tests at `LLMJSON`

If plan 001 created `JSONExtractionTests.swift` against the private methods,
re-target those tests to `LLMJSON.object(in:)` / `LLMJSON.array(in:)`. If plan
001 hasn't landed, create the file now. Cover: clean object/array; prose-prefixed;
```` ```json ````-fenced; none → nil; `} ... {` ordering behavior. Assert the
SAME outputs the old private methods produced (this is a no-behavior-change
refactor).

**Verify**: test command → `** TEST SUCCEEDED **`; the `LLMJSON` cases run.

## Test plan

- `OatmealTests/JSONExtractionTests.swift` targets `LLMJSON` with ≥ 8 cases
  across object + array.
- Model the test file on any test created in plan 001 (same XCTest structure).
- Verification: `** TEST SUCCEEDED **`.

## Done criteria

ALL must hold:
- [ ] `Oatmeal/Summary/LLMJSON.swift` exists with `object(in:)` + `array(in:)`.
- [ ] `SummarizationService`, `ActionItemExtractor`, `LiveAssistService` use
      `LLMJSON`; their private copies are gone
      (`grep -rn "func extractJSON\|func extractArray" Oatmeal/Summary` → empty).
- [ ] Build + tests succeed; `LLMJSON` is unit-tested.
- [ ] No prompt text changed (diff shows only extraction-call swaps).
- [ ] `plans/README.md` status row updated.

## STOP conditions

Stop and report if:
- A service's `parse` does something subtly different from first-open/last-close
  that `LLMJSON` wouldn't reproduce — preserve behavior, report the difference.
- The broader prompt-assembly duplication tempts you to refactor prompt text —
  STOP; that's deliberately out of scope (it changes LLM output).

## Maintenance notes

- **Deferred follow-up**: a `PromptBuilder` consolidating the `NOTES:` /
  `TRANSCRIPT:` block assembly + `truncateTranscript()` across the 8 Summary
  services. Higher risk because it alters prompt strings; do it behind
  golden-output tests, separately.
- Once `LLMJSON` is the single extractor, hardening (e.g. stripping ```` ``` ````
  fences before slicing) is a one-file change with test coverage — a good
  first improvement after this lands.
