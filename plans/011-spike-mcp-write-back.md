# Plan 011 (SPIKE): Design an MCP write-back path for agents

> **Executor instructions**: This is a DESIGN/SPIKE plan, not a build-everything
> plan. The deliverable is a written design doc + a small throwaway prototype +
> a list of decisions for the maintainer. Do NOT ship a production write API from
> this plan. Update `plans/README.md` when the design doc is delivered.

## Status

- **Priority**: P3 (direction — maintainer decides)
- **Effort**: M (spike), L (eventual implementation)
- **Risk**: MED — writes from agents touch the live store
- **Depends on**: plans/003 (saves via SafeStore) should land before any real write path
- **Category**: direction
- **Planned at**: commit `23dc9c8`, 2026-06-14

## Why this matters

`OatmealMCP` exposes meetings read-only (`list_meetings`, `get_meeting`,
`search_meetings`). The natural next capability is letting an agent act —
"log that decision as an action item," "add a tag." The data layer already has
the safe primitive (`SafeStore`), so the value is real. But there's a hard
architectural fact to design around (below), so this is a spike, not a build.

## Current state / the key constraint

`OatmealMCP/main.swift` is a **standalone stdio tool** that reads a static JSON
mirror file (`~/Library/Application Support/Oatmeal/mcp-meetings.json`, written
by `Oatmeal/MCP/MCPExport.swift`). It has **no connection to the live SwiftData
store and no access to the running app**:
- `loadMeetings()` reads the mirror file; tools format from that snapshot.
- `MCPExport.sync(context:)` writes the mirror from the app side.

So a write tool in `oatmeal-mcp` cannot directly mutate the store. Any write-back
requires one of these architectures — evaluating them IS the spike:
1. **Command-queue / outbox**: the MCP tool writes a pending-mutation file (e.g.
   `mcp-inbox.json`); the app watches it and applies mutations via `SafeStore`
   on the main actor, then refreshes the mirror. Decoupled, but eventually
   consistent and needs conflict/validation handling.
2. **App-hosted MCP**: move the MCP server into the running app process (or an
   XPC service) so tools call the live store directly. Most direct, but a bigger
   architectural change and only works while the app is running.
3. **Local IPC** (XPC / unix socket) between `oatmeal-mcp` and the app.

## Scope (of the spike)

**In scope**: a written design doc at `docs/design/mcp-write-back.md`; a minimal
throwaway prototype of the chosen approach proving one mutation
(`add_action_item`) end-to-end on a SCRATCH copy of the mirror/store (not the
user's real data); an open-questions list.

**Out of scope**: shipping a production write API; auth hardening; more than one
prototype tool; touching the user's real `mcp-meetings.json`.

## Steps

1. **Read & confirm the constraint.** Read `OatmealMCP/main.swift` and
   `Oatmeal/MCP/MCPExport.swift` fully. Confirm in the doc that the MCP tool has
   no live-store access today.
2. **Evaluate the three architectures** above on: latency/consistency, works-
   while-app-closed?, complexity, security/trust boundary, and how writes get
   validated + saved via `SafeStore`. Recommend one with reasoning.
3. **Define the write tool surface** (proposed): `add_action_item(meeting_id,
   text, owner?, due?)`, `update_notes(meeting_id, text)`, `add_tag(meeting_id,
   tag)`. For each: input schema, validation rules (id exists; text non-empty;
   no oversized payloads; dates parsed via `TaskDates.parse`), and the SafeStore
   save call site.
4. **Trust boundary.** Document who may call writes (the local agent only;
   stdio, not network), what an agent must NOT be able to do (delete meetings,
   exfiltrate, mass-edit), and how malformed input is rejected.
5. **Throwaway prototype** of the recommended approach for `add_action_item`
   only, against a scratch store/mirror. Capture what worked / what's hard.
6. **Open questions** for the maintainer (e.g. "apply writes only while the app
   is running?", "echo a confirmation back to the agent?", "audit log of agent
   writes?").

**Verify**: `docs/design/mcp-write-back.md` exists with all six sections; the
prototype ran one mutation on scratch data without touching real data.

## Done criteria

- [ ] Design doc with: the constraint, the three architectures evaluated + a
      recommendation, the proposed tool schemas + validation, the trust boundary,
      prototype findings, and open questions.
- [ ] Prototype exercised exactly one mutation on a scratch copy.
- [ ] No production write API shipped; no real user data modified.
- [ ] `plans/README.md` updated.

## STOP conditions

- If the prototype would require modifying the user's real store/mirror to
  demonstrate — STOP; use a scratch copy or a synthetic store only.
- If the recommended architecture turns out to need an XPC/entitlement change
  that's out of proportion to a spike — document and stop; don't implement it.

## Maintenance notes

- Real implementation must route every write through `SafeStore` on the
  `@MainActor`, validate inputs, and refresh the mirror after.
- Update `CLAUDE.md` privacy section: writes are local-agent-only, never network.
