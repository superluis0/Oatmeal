# Plan 013 (SPIKE): Evaluate an inbound webhook / import endpoint

> **Executor instructions**: DESIGN/SPIKE plan. Deliverable is a design doc with
> a clear recommendation (which may be "don't build this") — NOT a running HTTP
> server. Update `plans/README.md` when delivered.

## Status

- **Priority**: P3 (direction)
- **Effort**: M (spike)
- **Risk**: HIGH (an inbound network surface conflicts with the privacy posture)
- **Depends on**: none
- **Category**: direction
- **Planned at**: commit `23dc9c8`, 2026-06-14

## Why this matters

Oatmeal can POST a finished meeting outbound (`WebhookService`) but has no way
for an external system to push a meeting in. An inbound path would enable
"transcribe this voice note into Oatmeal" style workflows. BUT: the app's entire
value proposition is that it makes essentially no inbound network surface
available, so this must be evaluated soberly — the honest spike outcome may be
"local-only import instead of a network endpoint."

## Current state

- Outbound only: `Oatmeal/Integrations/WebhookService.swift` POSTs to a
  user-configured URL; default install makes no outbound calls.
- The app has **no HTTP server** today. `OatmealMCP` is stdio, not network.
- Privacy invariant (README "Privacy"): the only network activity is the local
  LLM, the one-time model download, and the optional update check. An inbound
  listener would be a brand-new network surface.

## Scope (of the spike)

**In scope**: `docs/design/inbound-import.md` evaluating options + a
recommendation. No server code, no new entitlements.

**Out of scope**: standing up any listener; binding a port; auth implementation.

## Steps

1. **Frame the privacy tension.** State plainly that an inbound HTTP listener
   contradicts the "no inbound surface" promise, and what would have to be true
   to justify it (off by default, localhost-only bind, mandatory shared-secret
   HMAC, explicit user opt-in with a clear warning).
2. **Evaluate options:**
   - (a) **No network — file-drop import**: watch a user-chosen folder; importing
     a dropped JSON/Markdown file creates a meeting. Achieves most of the value
     with zero network surface. (Overlaps plan 012's importer.)
   - (b) **Localhost-only HTTP**, off by default, HMAC-signed, bound to
     127.0.0.1: enables Zapier-via-local-bridge etc., but adds a real surface.
   - (c) **Share-extension / Shortcuts action**: macOS-native ingestion without a
     socket.
   Compare on privacy surface, user value, effort, and macOS sandbox/entitlement
   implications.
3. **Define the inbound payload schema** (title, transcript, attendees, optional
   summary, optional audio reference) regardless of transport, plus validation
   (size limits, schema rejection, no path traversal on any referenced file).
4. **Recommend.** Likely (a) or (c) over (b) for a privacy-first app — but let
   the analysis lead. If recommending against any network listener, say so
   clearly; "don't build this" is a valid spike result.
5. **Open questions** for the maintainer.

**Verify**: `docs/design/inbound-import.md` exists with the tension framed,
options compared, a payload schema, and a clear recommendation.

## Done criteria

- [ ] Design doc comparing file-drop vs localhost-HTTP vs Shortcuts/Share, with
      a privacy-surface analysis and a recommendation (incl. the option to not
      build a network listener).
- [ ] A validated inbound payload schema.
- [ ] No server/listener code; no entitlement changes.
- [ ] `plans/README.md` updated.

## STOP conditions

- If evaluating an option would require adding a network entitlement or binding a
  port to demonstrate — STOP; this is a paper spike only.

## Maintenance notes

- Whatever ships, it must be off by default and never weaken the documented
  privacy invariant; reflect the decision in `CLAUDE.md`.
- Coordinate with plan 012 — a file-drop importer reuses that parser.
