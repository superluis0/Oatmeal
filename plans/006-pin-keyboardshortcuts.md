# Plan 006: Pin `KeyboardShortcuts` to an exact version

> **Executor instructions**: Follow step by step; verify the build. STOP on any
> STOP condition. Update `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat 23dc9c8..HEAD -- project.yml .gitignore`

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: migration
- **Planned at**: commit `23dc9c8`, 2026-06-14

## Why this matters

`Package.resolved` is gitignored (`.gitignore:25`), so the only thing pinning
dependency versions is `project.yml`. `FluidAudio` is pinned exactly with a
comment explaining that a silent minor-version change once broke solo
recordings. `KeyboardShortcuts`, however, uses a floating range
(`from: "2.0.0"`), so different machines/CI can resolve different versions and
a future release lands silently — exactly the drift the FluidAudio pin exists
to prevent. Pinning it exactly makes builds reproducible and dependency updates
deliberate, consistent with the project's own stated discipline.

## Current state

`project.yml:7-17`:
```yaml
packages:
  FluidAudio:
    # Pinned EXACTLY: Package.resolved is gitignored, so a `from:` range let the
    # library drift silently between builds (0.15.x changed silent-audio
    # diarization from "no segments" to throwing noSpeechDetected, breaking solo
    # recordings until buildTranscript caught it). Upgrades should be deliberate.
    url: https://github.com/FluidInference/FluidAudio.git
    exactVersion: "0.15.2"
  KeyboardShortcuts:
    url: https://github.com/sindresorhus/KeyboardShortcuts.git
    from: "2.0.0"
```

`.gitignore:25` contains `Package.resolved`.

You must determine the **currently resolved** KeyboardShortcuts version and pin
to it (pinning to a version you've actually built against, not a guessed one).

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| Find resolved version | `find /tmp/OatmealBuild ~/Library/Developer/Xcode/DerivedData -name "Package.resolved" 2>/dev/null -exec grep -A3 -i "keyboardshortcuts" {} +` | shows the resolved `version` |
| Alt: resolved in repo | `find . -name "Package.resolved" -exec grep -A3 -i keyboardshortcuts {} +` | may be empty (gitignored) |
| Regenerate | `xcodegen generate` | exit 0 |
| Build | `xcodebuild -project Oatmeal.xcodeproj -scheme Oatmeal -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/OatmealBuild build` | `** BUILD SUCCEEDED **` |

## Scope

**In scope** (modify): `project.yml` (the `KeyboardShortcuts` package entry only).

**Out of scope**:
- `FluidAudio` pin (already correct).
- `.gitignore` (committing `Package.resolved` is a reasonable alternative but is
  a separate decision — do NOT change it in this plan; note it in Maintenance).
- Any source code.

## Steps

### Step 1: Determine the resolved version

Run the "Find resolved version" command. If no `Package.resolved` exists yet,
run a build first (it generates one under the derived-data path), then re-run.
Record the exact version string (e.g. `2.4.0`).

**Verify**: you have a concrete version number that the project currently builds
with.

### Step 2: Pin it exactly with a rationale comment

Replace:
```yaml
  KeyboardShortcuts:
    url: https://github.com/sindresorhus/KeyboardShortcuts.git
    from: "2.0.0"
```
with (substitute the version you found):
```yaml
  KeyboardShortcuts:
    # Pinned EXACTLY for reproducible builds — Package.resolved is gitignored,
    # so a `from:` range would let the version drift silently between machines.
    # Bump deliberately. (Same rationale as FluidAudio above.)
    url: https://github.com/sindresorhus/KeyboardShortcuts.git
    exactVersion: "<RESOLVED_VERSION>"
```

**Verify**: `xcodegen generate` → exit 0, then build → `** BUILD SUCCEEDED **`.

### Step 3: Confirm keyboard shortcuts still function

The dependency drives global shortcuts (see
`Oatmeal/Shortcuts/KeyboardShortcutNames.swift` and usages). A successful build
is the primary gate. If you can run the app, confirm a configured global
shortcut still triggers; otherwise note that runtime wasn't verified.

## Test plan

- No unit test applies (build-system change). Verification is
  `xcodegen generate` + a clean build against the pinned version.

## Done criteria

ALL must hold:
- [ ] `project.yml` pins `KeyboardShortcuts` with `exactVersion` (not `from:`),
      to the version the project currently resolves.
- [ ] A rationale comment is present.
- [ ] `xcodegen generate` and the build both succeed.
- [ ] `plans/README.md` status row updated.

## STOP conditions

Stop and report if:
- You cannot determine the resolved version from any `Package.resolved`
  (don't guess a version — report and ask).
- Pinning to the resolved version fails to build (unexpected; report the error).

## Maintenance notes

- Consider, separately, **un-gitignoring `Package.resolved`** and committing it —
  that pins the entire transitive graph and is the more robust fix; exact-version
  pins in `project.yml` only cover direct deps. Left out of this plan to keep it
  single-purpose; raise as a follow-up.
- When intentionally upgrading either dependency, bump the `exactVersion` and
  smoke-test (shortcuts for KeyboardShortcuts; solo + multi-speaker recording
  for FluidAudio).
