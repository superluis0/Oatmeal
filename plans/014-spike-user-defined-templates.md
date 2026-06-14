# Plan 014 (SPIKE): Design user-defined note templates

> **Executor instructions**: DESIGN/SPIKE plan. Deliverable is a design doc +
> a loader prototype with tests, NOT a shipped editor UI. Update
> `plans/README.md` when delivered.

## Status

- **Priority**: P3 (direction)
- **Effort**: M (spike), L (implementation)
- **Risk**: LOW (orthogonal; degrades gracefully)
- **Depends on**: plans/001 (so the loader/validator ships with tests)
- **Category**: direction
- **Planned at**: commit `23dc9c8`, 2026-06-14

## Why this matters

Note templates shape every meeting's generated notes, but they're hardcoded
builtins — teams/power users with a required note format must fork the app to
change them. User-defined templates are high-leverage UX with low architectural
risk, since templates are already a first-class concept.

## Current state

- `Oatmeal/Model/NoteTemplate.swift` defines the template type; builtins are
  provided via `Oatmeal/Model/TemplateProvider.swift` and chosen in Settings.
  (Read both fully before designing; confirm the exact shape — sections,
  prompts, any per-template metadata — rather than assuming.)
- There is a `Oatmeal/Views/TemplateEditorView.swift` — read it: determine
  whether it already edits anything persistent or is a stub, since that changes
  the scope of "add custom templates."
- Templates feed the summarization/notes prompts (see `Oatmeal/Summary/`),
  so a malformed custom template could degrade note quality — validation matters.

## Scope (of the spike)

**In scope**: `docs/design/user-templates.md`; a prototype loader
`CustomTemplateLoader` that reads template definitions from
`~/Library/Application Support/Oatmeal/templates/*.json`, validates them, and
maps to the existing `NoteTemplate` type, with unit tests (valid, missing
fields, malformed JSON → graceful fallback to builtins).

**Out of scope**: the in-app template editor UI; migrating builtins to disk;
changing the summarization prompts.

## Steps

1. **Characterize the current template model.** Read `NoteTemplate.swift`,
   `TemplateProvider.swift`, `TemplateEditorView.swift`, and where templates are
   consumed in `Oatmeal/Summary/`. Document the exact fields a custom template
   must provide to be a drop-in.
2. **Define an on-disk schema** (JSON) mirroring `NoteTemplate` (e.g.
   `{ name, sections: [{ title, prompt, example? }] }` — match the real type).
   Define a storage location and load order (builtins + user templates; name
   collisions resolution).
3. **Prototype the loader + validator** (pure where possible): read the
   directory, decode, validate required fields and reasonable limits, map to
   `NoteTemplate`, fall back to builtins on any error (never crash, never ship a
   broken template to the LLM).
4. **Tests**: valid file → loads; missing required field → rejected with a clear
   reason; malformed JSON → ignored, builtins still load; name collision →
   documented resolution.
5. **Open questions** (editor UX, sharing/exporting templates, whether prompts
   should be sandboxed/limited, versioning/migration of the schema).

**Verify**: `docs/design/user-templates.md` exists; loader + tests run green;
no UI shipped.

## Done criteria

- [ ] Design doc: current model characterized, on-disk schema + storage/load
      order, validation rules, open questions.
- [ ] `CustomTemplateLoader` prototype + unit tests (valid/invalid/malformed/
      collision), all green.
- [ ] Graceful fallback to builtins on any load error (tested).
- [ ] No editor UI shipped; summarization prompts unchanged.
- [ ] `plans/README.md` updated.

## STOP conditions

- If `TemplateEditorView` turns out to ALREADY persist custom templates, STOP and
  report — the finding (and this plan) need rescoping to "finish/expose existing
  work" rather than "design from scratch."
- If templates are too entangled with prompt construction to load safely from
  disk without prompt changes — document the coupling and stop.

## Maintenance notes

- A broken custom template must never degrade silently to a bad LLM prompt —
  validation + fallback is the core safety requirement.
- Implementation order after the spike: loader (this) → Settings list of
  custom templates → editor UI.
