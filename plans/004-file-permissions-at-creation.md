# Plan 004: Create sensitive files with `0o600` at creation (close the TOCTOU window)

> **Executor instructions**: Follow step by step; verify each build. STOP and
> report on any STOP condition. Update `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat 23dc9c8..HEAD -- Oatmeal/Model/StoreBackup.swift Oatmeal/MCP/MCPExport.swift Oatmeal/Diagnostics/Log.swift`
> On any change, re-confirm the excerpts below before editing.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `23dc9c8`, 2026-06-14

## Why this matters

Oatmeal's whole promise is that meeting data stays private on the user's Mac.
Three files that hold full transcripts/notes (the MCP mirror and the backup
snapshot) or diagnostics (the log) are written first and then narrowed to
owner-only (`0o600`) on the *next* line. Between the write and the `chmod`
there is a brief window where the file carries the process umask's
permissions — on a system with a permissive umask, another local user could
read it. Creating the file with `0o600` from the start removes the window.
This is defense-in-depth, low-effort, and aligns the code with its stated
privacy posture.

## Current state

`Oatmeal/MCP/MCPExport.swift:39-45` (mirror holds full transcripts/notes):
```swift
try? FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
    try? data.write(to: url, options: [.atomic])
    // Restrict to owner-only — the mirror contains full transcripts/notes.
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}
```

`Oatmeal/Model/StoreBackup.swift:41-42` (full backup snapshot):
```swift
try? data.write(to: url, options: [.atomic])
try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
```

`Oatmeal/Diagnostics/Log.swift:77-78` and `:97` (log + rotation):
```swift
if !FileManager.default.fileExists(atPath: url.path) {
    FileManager.default.createFile(atPath: url.path, contents: nil)
}
...
FileManager.default.createFile(atPath: url.path, contents: nil)   // in rotate()
```

The cleanest primitive that sets permissions atomically at creation is
`FileManager.createFile(atPath:contents:attributes:)` with
`[.posixPermissions: 0o600]`. Note `Data.write(to:options:.atomic)` writes to a
temp file then renames, so a post-write `chmod` can't cover the temp file's
brief existence — replacing it with `createFile(...attributes:)` (non-atomic
but permission-correct) is the intended fix for these owner-private files.

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| Build | `xcodebuild -project Oatmeal.xcodeproj -scheme Oatmeal -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/OatmealBuild build` | `** BUILD SUCCEEDED **` |
| Confirm no stray chmod-after-write remains | `grep -rn "setAttributes(\[.posixPermissions" Oatmeal/MCP Oatmeal/Model/StoreBackup.swift` | only intentional ones (see Step) |

## Scope

**In scope** (modify): `Oatmeal/MCP/MCPExport.swift`,
`Oatmeal/Model/StoreBackup.swift`, `Oatmeal/Diagnostics/Log.swift`.

**Out of scope**:
- Any other file writer (exports the user explicitly chooses a destination for,
  e.g. `MarkdownExporter` Save panels — the user picks the location/permissions).
- The directory-creation calls (directory perms are a separate concern; leave
  `createDirectory` as-is).
- Changing the backup/mirror data shape or when they're written.

## Steps

### Step 1: MCPExport — create the mirror with `0o600`

Replace the `data.write` + `setAttributes` pair with a single
`createFile(atPath:contents:attributes:)`:
```swift
if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
    // Owner-only from creation — the mirror contains full transcripts/notes.
    FileManager.default.createFile(
        atPath: url.path, contents: data,
        attributes: [.posixPermissions: 0o600])
}
```
`createFile` overwrites an existing file's contents; if the file already exists
with `0o600`, permissions are preserved. Keep the `createDirectory` line above
it unchanged.

**Verify**: build → `** BUILD SUCCEEDED **`.

### Step 2: StoreBackup — create the snapshot with `0o600`

Replace:
```swift
try? data.write(to: url, options: [.atomic])
try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
```
with:
```swift
FileManager.default.createFile(
    atPath: url.path, contents: data,
    attributes: [.posixPermissions: 0o600])
```
Leave the preceding `createDirectory` and the "keep one previous generation"
copy logic untouched. (The prev-generation `copyItem` at lines 37-40 copies an
already-`0o600` file, so the copy inherits restricted perms — no change needed
there; verify by reading the surrounding lines.)

**Verify**: build → `** BUILD SUCCEEDED **`.

### Step 3: Log — create log + rotated log with `0o600`

In `openFile()` replace:
```swift
FileManager.default.createFile(atPath: url.path, contents: nil)
```
with:
```swift
FileManager.default.createFile(atPath: url.path, contents: nil,
                               attributes: [.posixPermissions: 0o600])
```
Do the same for the `createFile` in `rotate()`. (The crash-marker
`createFile(atPath: marker.path, contents: Data())` elsewhere is low-value —
it only records that a crash happened — optionally apply the same attribute for
consistency, but it is not required.)

**Verify**: build → `** BUILD SUCCEEDED **`.

### Step 4: Spot-check at runtime (optional but recommended)

If you can run the app once (`./reinstall.sh && open ~/Applications/Oatmeal.app`,
record a throwaway meeting, quit), then:
`stat -f "%Sp %N" ~/Library/Application\ Support/Oatmeal/mcp-meetings.json ~/Library/Application\ Support/Oatmeal/Logs/oatmeal.log`
→ permission string should be `-rw-------`. If you cannot run the app, skip and
note it; the static change is correct regardless.

## Test plan

- Behavior is unchanged except file mode; no unit test fits cleanly (these
  touch the real filesystem under Application Support).
- Verification is the build plus the optional `stat` check showing `-rw-------`.

## Done criteria

ALL must hold:
- [ ] MCPExport, StoreBackup, and Log create their files via
      `createFile(...attributes: [.posixPermissions: 0o600])`.
- [ ] No `write(to:options:.atomic)`-then-`setAttributes` pair remains in the
      three in-scope files.
- [ ] Build succeeds.
- [ ] (If run) `stat` shows `-rw-------` on the mirror and log.
- [ ] `plans/README.md` status row updated.

## STOP conditions

Stop and report if:
- Removing `.atomic` write raises a concern you can't resolve — e.g. the file
  is read concurrently by the `oatmeal-mcp` process such that a non-atomic
  rewrite could yield a torn read. (If so, keep the atomic write and instead
  `chmod` the destination both before and after, or pre-create the file
  `0o600` then atomically overwrite — report and propose.)
- An excerpt doesn't match live code (drift).

## Maintenance notes

- The MCP mirror is read by `OatmealMCP` (`oatmeal-mcp`); if that process is
  ever changed to memory-map or hold the file open, revisit whether
  non-atomic rewrite is safe (see STOP condition).
- Any new writer of meeting-derived data under Application Support should use
  the same `createFile(...attributes:)` pattern; mention this in `CLAUDE.md`
  (plan 002) privacy section.
