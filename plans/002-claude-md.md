# Plan 002: Add a `CLAUDE.md` that captures the non-obvious invariants

> **Executor instructions**: Follow this plan step by step. This plan creates a
> single documentation file; there is no code to build, but you MUST verify
> every factual claim against the cited source before writing it. If a claim
> can't be verified, omit it and note so. Update `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat 23dc9c8..HEAD -- reinstall.sh project.yml README.md Oatmeal/Model/SafeStore.swift`
> If these changed, re-verify the excerpts below against live code first.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: dx
- **Planned at**: commit `23dc9c8`, 2026-06-14

## Why this matters

Several hard-won, non-obvious invariants live only in scattered comments,
`reinstall.sh`, and git history. An agent or new contributor will re-derive
(or violate) them: the build-to-`/tmp` codesign quirk, the XcodeGen workflow,
the recurring SwiftData deleted-object crash class, the `SafeStore` save
pattern, and the privacy/no-network-egress invariant that is the product's
entire reason to exist. A one-page `CLAUDE.md` at the repo root pays for itself
the first time it prevents a reintroduced crash or an accidental network call.

## Current state

- **No `CLAUDE.md` or `AGENTS.md`** exists at the repo root or under `Oatmeal/`.
- Build quirk is documented only in `reinstall.sh` and `README.md:144-146`
  ("Xcode can't code-sign inside an iCloud-synced folder"). Verify the build
  command in `reinstall.sh`.
- XcodeGen workflow: `README.md:199-200` — "make project/target changes in
  `project.yml` and run `xcodegen generate` (don't edit the `.xcodeproj`)".
- SwiftData deleted-object crash class: see git log
  (`git log --oneline | grep -i "deleted\|SwiftData\|crash"`) and the guard
  pattern in `Oatmeal/Views/MeetingDetailView.swift` (the `body`/content guards
  checking `meeting.isDeleted || meeting.modelContext == nil`).
- `SafeStore` save pattern: `Oatmeal/Model/SafeStore.swift:9-31` — wraps
  `context.save()` in an ObjC-exception catcher and rolls back instead of
  crashing. Its doc comment explains why `try?` is insufficient.
- Privacy invariant: `README.md:167-178` — audio/notes never leave the Mac;
  the only network is the user's local LLM, a one-time model download, and an
  optional once-a-day GitHub update check.
- Dependency pinning rationale: `project.yml:8-14` (FluidAudio pinned exactly
  with a comment about a silent diarization behavior change).

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| Verify build command | `grep -n "xcodebuild\|derivedDataPath\|/tmp" reinstall.sh` | shows the build-to-/tmp invocation |
| Verify SafeStore doc | `sed -n '1,31p' Oatmeal/Model/SafeStore.swift` | matches the excerpt above |
| Verify crash-fix history | `git log --oneline \| grep -iE "deleted\|swiftdata\|crash"` | lists multiple commits |

## Scope

**In scope** (create): `CLAUDE.md` at the repo root.

**Out of scope**: any code change; editing `README.md`; creating
`.github/` or CI config (that's a separate concern).

## Git workflow

- Branch: `advisor/002-claude-md`
- Single commit, subject e.g. "Add CLAUDE.md with build + SwiftData + privacy invariants".

## Steps

### Step 1: Verify each claim, then write `CLAUDE.md`

Run the three verification commands above. Then write `CLAUDE.md` with these
sections (keep it ~1 page; link to source rather than duplicating):

1. **What this is** — one paragraph: private, on-device macOS meeting-notes app
   (SwiftUI + SwiftData), local LLM via LM Studio, FluidAudio ASR/diarization.
2. **Build & run** — the exact `/tmp` build command (copied verbatim from
   `reinstall.sh`), why it must build outside the repo (iCloud-synced path
   breaks codesign), and the XcodeGen rule: edit `project.yml`, run
   `xcodegen generate`, never hand-edit `Oatmeal.xcodeproj`. Mention
   `./reinstall.sh` as the scripted path.
3. **Tests** — how to run them (`xcodebuild test ... -derivedDataPath /tmp/OatmealBuild`).
   If plan 001 hasn't landed yet, say "test target is being established in
   plans/001" and update once it exists.
4. **SwiftData safety (READ BEFORE TOUCHING VIEWS)** — the deleted-object crash
   class: reading a relationship/attribute of a deleted `@Model` traps. Guard
   with `meeting.isDeleted || meeting.modelContext == nil` before reading in a
   view body, and prefer the `liveX` accessors on `Models.swift`. Point at the
   guard in `MeetingDetailView` as the canonical example.
5. **Saving** — always go through `SafeStore.save(context:)`, never raw
   `try? context.save()`: `try?` cannot catch the ObjC exceptions SwiftData
   raises (e.g. saving a relationship to a deleted row), which abort the app.
   (Note: plan 003 is migrating the remaining raw saves.)
6. **Privacy invariant (DO NOT VIOLATE)** — no telemetry, no analytics, no
   network egress except: (a) the user-configured local LLM base URL, (b) the
   one-time FluidAudio model download, (c) the optional once-a-day GitHub
   update check. Any new `URLSession`/network call outside these three is a
   defect. Webhook/MCP are opt-in/local.
7. **Dependencies** — pinned deliberately; see `project.yml`. Don't loosen pins.

Write in plain, imperative prose. Do not invent commands — use only what the
verification steps confirmed.

**Verify**: `test -f CLAUDE.md && wc -l CLAUDE.md` → file exists, roughly
60-120 lines. `grep -c "SafeStore\|/tmp\|xcodegen\|egress\|isDeleted" CLAUDE.md`
→ ≥ 5 (all key invariants mentioned).

## Test plan

No automated tests (documentation). Manual check: each of the 7 sections is
present and every command/claim traces to a verified source.

## Done criteria

ALL must hold:
- [ ] `CLAUDE.md` exists at repo root.
- [ ] Build section contains the verbatim `/tmp` build command from `reinstall.sh`.
- [ ] SwiftData + SafeStore + privacy-egress sections are present.
- [ ] No unverified commands or invented file paths.
- [ ] `plans/README.md` status row updated.

## STOP conditions

Stop and report if:
- The build command in `reinstall.sh` differs materially from the README's
  description (resolve which is correct before documenting).
- `SafeStore.swift` no longer matches the excerpt (drift).

## Maintenance notes

- Update the Tests section once plan 001 lands.
- Update the Saving section once plan 003 finishes migrating raw saves.
- If a future change legitimately adds a network endpoint, the privacy section
  must be updated in the SAME change, and the reviewer should treat a new
  `URLSession` call as requiring explicit justification.
