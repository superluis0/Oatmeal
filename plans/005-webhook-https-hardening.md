# Plan 005: Warn on (or block) plaintext-HTTP webhook URLs

> **Executor instructions**: Follow step by step; verify each build. STOP on any
> STOP condition. Update `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat 23dc9c8..HEAD -- Oatmeal/Integrations/WebhookService.swift Oatmeal/Views/SettingsView.swift`

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `23dc9c8`, 2026-06-14

## Why this matters

The optional webhook posts a finished meeting's title, summary, and action
items — all transcript-derived, sensitive content — to a user-configured URL.
The current validation accepts both `http` and `https`. If a user pastes an
`http://` URL, every summary is sent in cleartext, which undercuts the app's
core privacy guarantee on any shared/untrusted network. The fix is small:
warn the user in the Settings UI when the webhook URL is plaintext HTTP (and
optionally refuse to send over HTTP unless they explicitly opt in).

## Current state

`Oatmeal/Integrations/WebhookService.swift` (full file):
```swift
struct WebhookService {
    func postIfConfigured(title: String, summary: String, actionItems: [String]) async {
        let urlString = AppSettings.webhookURL.trimmingCharacters(in: .whitespaces)
        // Only http(s) with a real host — blocks file://, ftp://, data:, etc.
        guard !urlString.isEmpty, let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host != nil else { return }
        ...
        _ = try? await URLSession.shared.data(for: request)
    }
}
```

The webhook URL is configured in `Settings → ...`; find the field in
`Oatmeal/Views/SettingsView.swift` (search for `webhookURL`). `AppSettings` is
defined in `Oatmeal/Summary/Settings.swift` (search for `webhookURL` to see how
it's stored — likely `@AppStorage`/`UserDefaults`).

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| Locate the settings field | `grep -rn "webhookURL" Oatmeal/Views/SettingsView.swift Oatmeal/Summary/Settings.swift` | shows the binding + storage |
| Build | `xcodebuild -project Oatmeal.xcodeproj -scheme Oatmeal -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/OatmealBuild build` | `** BUILD SUCCEEDED **` |

## Scope

**In scope** (modify): `Oatmeal/Views/SettingsView.swift` (add the warning UI);
optionally `Oatmeal/Integrations/WebhookService.swift` (only if you implement
the stricter "block HTTP" variant — see Step 2, choose ONE variant).

**Out of scope**:
- The webhook payload shape and the rest of `postIfConfigured`.
- `file://`/`ftp://` blocking — already correct, leave it.
- Adding new settings keys beyond what the chosen variant needs.

## Steps

### Step 1: Add an inline warning in Settings when the URL is HTTP

In `SettingsView.swift`, near the webhook URL field, add a conditional caption
shown only when the trimmed `webhookURL` starts with `http://` (case-insensitive)
and is non-empty. Match the file's existing style for hints/captions (search
the file for an existing `.font(.caption)` / `Text(...).foregroundStyle` hint
and mirror it). Text, e.g.:
> "This webhook uses unencrypted HTTP. Meeting summaries would be sent in
> cleartext. Use an `https://` URL."

Use a warning tint consistent with the codebase (search `Theme.danger` /
`.orange` usage for the convention).

**Verify**: build → `** BUILD SUCCEEDED **`. Manual: with an `http://` URL the
caption appears; with `https://` it does not. (If you can't run the UI, confirm
the conditional compiles and the predicate is correct.)

### Step 2: (Choose ONE) — keep send-but-warn, OR block HTTP by default

**Variant A (recommended, least surprising): warn only.** No change to
`WebhookService`; Step 1 is sufficient. The user retains control (some users
intentionally hit a localhost `http://` collector). Document the choice.

**Variant B (stricter): refuse HTTP unless explicitly allowed.** Add a single
boolean setting `webhookAllowInsecureHTTP` (default `false`) next to the URL
field with a checkbox "Allow unencrypted HTTP (not recommended)". In
`WebhookService.postIfConfigured`, change the scheme guard so that `http` is
permitted only when that flag is true:
```swift
let allowInsecure = AppSettings.webhookAllowInsecureHTTP
guard !urlString.isEmpty, let url = URL(string: urlString),
      let scheme = url.scheme?.lowercased(),
      scheme == "https" || (scheme == "http" && allowInsecure),
      url.host != nil else { return }
```
Pick Variant A unless the operator asked for hard enforcement. Do NOT implement
both.

**Verify**: build → `** BUILD SUCCEEDED **`.

## Test plan

- If plan 001 has landed and you chose Variant B, add a small pure helper
  `WebhookService.isAcceptable(urlString:allowInsecure:) -> Bool` and unit-test
  it: `https://x` → true; `http://x` with flag false → false; with flag true →
  true; `file:///etc/passwd` → false; empty → false; no host → false. Refactor
  the guard to call this helper so it's testable.
- For Variant A, the change is UI-only; manual verification suffices.

## Done criteria

ALL must hold:
- [ ] Settings shows a visible warning when the webhook URL is `http://`.
- [ ] (Variant B only) HTTP is rejected unless `webhookAllowInsecureHTTP` is on,
      with a covering unit test.
- [ ] `file://`/`ftp://`/`data:` are still blocked (unchanged guard logic).
- [ ] Build succeeds.
- [ ] `plans/README.md` status row updated.

## STOP conditions

Stop and report if:
- You can't find where `webhookURL` is bound in `SettingsView` (the settings
  layout may have moved — report so the field can be located).
- Implementing Variant B would require touching how `AppSettings` persists in a
  way that ripples beyond one new key.

## Maintenance notes

- If a future feature sends any other meeting-derived data outbound, apply the
  same HTTPS expectation and reflect it in `CLAUDE.md` (plan 002).
- Reviewer should confirm the non-web-scheme blocking is unchanged.
