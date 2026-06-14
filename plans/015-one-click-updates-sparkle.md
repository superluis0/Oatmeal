# Plan 015: One-click in-app updates via Sparkle (self-signed / Path B)

> **Executor instructions**: This is a LARGE feature spanning app code, signing
> keys, and a release pipeline. Do it in the PHASES below, verifying after each.
> Several steps require the **maintainer's** action (Apple machine, Keychain
> keys, GitHub release/Pages) — those are marked **[MAINTAINER]**; when you hit
> one and can't perform it, STOP and hand back with exactly what's needed. Do not
> fabricate keys, signatures, or release artifacts. Update `plans/README.md` as
> you complete phases.
>
> **Drift check (run first)**: `git diff --stat 23dc9c8..HEAD -- Oatmeal/OatmealApp.swift Oatmeal/Diagnostics/UpdateChecker.swift Oatmeal/Views/SettingsView.swift Oatmeal/Views/MeetingListView.swift project.yml Oatmeal/Info.plist reinstall.sh`
> NOTE: `MeetingListView.swift` has uncommitted changes from a prior session;
> locate the update pill by the `updateChecker.available` symbol, not line number.

## Status

- **Priority**: P2 (requested feature)
- **Effort**: L
- **Risk**: MED (release/signing infrastructure; mis-signing breaks TCC grants)
- **Depends on**: none (independent of the audit plans; pairs naturally with 006's pinning discipline)
- **Category**: direction / dx
- **Planned at**: commit `23dc9c8`, 2026-06-14

## Why this matters

Today the "Update" pill only deep-links to GitHub Releases, where the user must
rebuild from source — there is no prebuilt binary and no in-app install. This
plan delivers genuine **one-click updates** using **Sparkle** (the de-facto
macOS updater) on the **free, self-signed path**: every release is signed with
the existing `Oatmeal Self-Signed` identity and authenticated with an EdDSA
signature, so Sparkle can download, verify, swap, and relaunch the app in place.

The single most important constraint, and the reason this plan is careful:
**macOS remembers Microphone / Screen-Recording grants by the app's signing
identity.** The project already maintains a *stable* self-signed cert
(`Oatmeal Self-Signed`) precisely so rebuilds keep those grants. A Sparkle update
preserves the grants **only if the downloaded build is signed with that same
identity.** Sign a release any other way and the user re-grants every permission.

## Current state

- **No prebuilt artifact, no CI**: `.github/workflows/` does not exist; releases
  ship source. `reinstall.sh` builds locally to `/tmp`, signs with
  `Oatmeal Self-Signed` (+ `Oatmeal/Oatmeal.entitlements`), and installs to
  `~/Applications` ([reinstall.sh:78](../reinstall.sh)).
- **Signing posture** (favorable for Sparkle): `ENABLE_HARDENED_RUNTIME: NO`,
  **not sandboxed** (`com.apple.security.app-sandbox` = false in
  `Oatmeal/Oatmeal.entitlements`), `network.client` entitlement present. Non-
  sandboxed + hardened-runtime-off is Sparkle's *simplest* integration (no XPC
  installer-service entitlements required).
- **Existing update UI to reuse** (do NOT build a parallel one):
  - `Oatmeal/Diagnostics/UpdateChecker.swift` — an `@Observable @MainActor`
    singleton that polls the GitHub API once/day and exposes
    `var available: Release?`.
  - The sidebar pill reads `updateChecker.available` and shows a `Link` to the
    release page (`Oatmeal/Views/MeetingListView.swift`, search
    `updateChecker.available`).
  - Settings → Updates section (`Oatmeal/Views/SettingsView.swift`, search
    `updateChecker`) with a "Check now" button and the once-a-day explanation.
- **App entry** (`Oatmeal/OatmealApp.swift`): SwiftUI `App`; has a `.commands { }`
  block (currently only `CommandGroup(replacing: .newItem) {}`) — this is where a
  "Check for Updates…" menu item goes. `Info.plist` is hand-managed
  (`GENERATE_INFOPLIST_FILE: NO`, `INFOPLIST_FILE: Oatmeal/Info.plist`).
- Version source of truth: `project.yml` `MARKETING_VERSION: "0.4.0"`,
  `CURRENT_PROJECT_VERSION: "4"` (Sparkle compares `CFBundleVersion`).

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| Regenerate project | `xcodegen generate` | exit 0 |
| Build | `xcodebuild -project Oatmeal.xcodeproj -scheme Oatmeal -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/OatmealBuild build` | `** BUILD SUCCEEDED **` |
| Locate Sparkle tools after SPM resolve | `find ~/Library/Developer/Xcode/DerivedData /tmp/OatmealBuild -name "generate_keys" -o -name "sign_update" -o -name "generate_appcast" 2>/dev/null` | paths to Sparkle's CLI tools |
| Find update UI sites | `grep -rn "updateChecker.available\|UpdateChecker" Oatmeal --include="*.swift"` | the integration points |

## Dependency-safety gate (do FIRST, before `xcodegen generate` pulls it)

Adding Sparkle is a new dependency. Before it resolves:
- Confirm the package is the real one: **`https://github.com/sparkle-project/Sparkle`**
  (Sparkle 2.x; the long-standing, widely-used macOS updater — not a typosquat).
- Pick a version that has been **public for at least 7 days** (check the GitHub
  releases page) and pin it **exactly** (consistent with this repo's FluidAudio
  discipline — see `project.yml:8-14`). Record the version + its release date in
  the PR description.
- **[MAINTAINER] confirm before proceeding** — do not let the build resolve a
  brand-new Sparkle release unprompted.

## Scope

**In scope**:
- `project.yml` — add the pinned Sparkle SPM package + link it to `Oatmeal`.
- `Oatmeal/OatmealApp.swift` — instantiate the Sparkle updater + a
  "Check for Updates…" menu command.
- `Oatmeal/Diagnostics/UpdateChecker.swift` — repurpose to delegate to Sparkle
  (drive `available` from Sparkle's update-found callback) instead of polling the
  GitHub API. Keep the public shape (`available`, `check()`, `isChecking`) so the
  existing pill + Settings UI keep working.
- `Oatmeal/Info.plist` — add `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`.
- A release script (new `release.sh`, or a `.github/workflows/release.yml`) that
  builds, signs with `Oatmeal Self-Signed`, zips, EdDSA-signs, and updates the
  appcast.
- An `appcast.xml` and its hosting (recommend `docs/` via GitHub Pages).

**Out of scope**:
- Developer ID / notarization (that's Path A — a future upgrade; the Sparkle
  wiring here does not change when you adopt it).
- Auto-installing silently without user consent (always show Sparkle's prompt).
- Sandboxing the app or enabling Hardened Runtime.
- Touching the audit plans' files beyond the update UI.

## Phases

### Phase 1 — Integrate Sparkle in-app (compiles + checks a feed)

1. **[MAINTAINER gate]** After the dependency-safety gate above, add to
   `project.yml` under `packages:` (substitute the confirmed version):
   ```yaml
     Sparkle:
       # Pinned exactly (Package.resolved is gitignored). The macOS auto-updater.
       url: https://github.com/sparkle-project/Sparkle.git
       exactVersion: "<CONFIRMED_VERSION>"
   ```
   and add to the `Oatmeal` target `dependencies:`:
   ```yaml
       - package: Sparkle
         product: Sparkle
   ```
2. `xcodegen generate` → build. Resolving SPM downloads Sparkle (incl. its CLI
   tools `generate_keys` / `sign_update` / `generate_appcast` under the SPM
   artifacts — note their paths for later phases).
3. In `OatmealApp.swift`, add a standard updater controller and a menu command:
   ```swift
   import Sparkle
   // in OatmealApp:
   private let updaterController = SPUStandardUpdaterController(
       startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
   // in .commands { } (add a new group; keep the existing newItem replacement):
   CommandGroup(after: .appInfo) {
       Button("Check for Updates…") { updaterController.updater.checkForUpdates() }
   }
   ```
4. Build. Without a valid `SUFeedURL` yet, the menu item exists but a check will
   fail gracefully — that's expected until Phase 2/3.

**Verify (Phase 1)**: `xcodegen generate` + build succeed; the app launches and
"Check for Updates…" appears under the app menu. Commit.

### Phase 2 — Keys + Info.plist

1. **[MAINTAINER]** Generate the EdDSA keypair with Sparkle's tool:
   `./generate_keys` (from the Sparkle artifacts path found in Phase 1). It stores
   the **private** key in the login Keychain (the maintainer keeps it; it never
   enters the repo) and prints the **public** key (base64).
2. Add to `Oatmeal/Info.plist`:
   - `SUFeedURL` = the appcast URL chosen in Phase 3 (e.g.
     `https://superluis0.github.io/Oatmeal/appcast.xml`).
   - `SUPublicEDKey` = the printed public key.
   - `SUEnableAutomaticChecks` = `true` (optional: `SUScheduledCheckInterval`).
3. Repurpose `UpdateChecker`: replace its GitHub-API polling with a Sparkle-backed
   source of truth so the existing pill keeps working. Make `UpdateChecker`
   conform to `SPUUpdaterDelegate` and set `available` from
   `updater(_:didFindValidUpdate:)` (map Sparkle's `SUAppcastItem` →
   `Release(version:url:)`); on the pill/Settings "check" action call
   `updaterController.updater.checkForUpdates()`. Wire the controller's
   `updaterDelegate` to this object in `OatmealApp`. Keep the public API
   (`available`, `isChecking`, `check()`) so `MeetingListView` and `SettingsView`
   need minimal/no change — but change the pill from a bare `Link` to an action
   that invokes the Sparkle update flow (download + install), since one-click
   install is the whole point.

**Verify (Phase 2)**: build succeeds; `Info.plist` contains the three SU keys;
`UpdateChecker` no longer calls `api.github.com` (grep confirms the GitHub URL is
gone from it). Update `CLAUDE.md` (if plan 002 landed) — the privacy note now
lists Sparkle's appcast fetch as a known network call.

### Phase 3 — Release pipeline + appcast + end-to-end test

1. **Signing nested code (critical).** Sparkle embeds nested executables
   (`Autoupdate`, `Updater.app`, XPC services) inside `Sparkle.framework`. These
   MUST be code-signed. The repo's current `codesign --force --deep` is
   deprecated and can mis-sign nested bundles. Sign **inside-out**: sign Sparkle's
   nested helpers, then the framework, then the app — follow Sparkle's
   "Sign updates / Distribution" docs. The app itself is signed with
   `Oatmeal Self-Signed` + `Oatmeal/Oatmeal.entitlements` (SAME identity as
   `reinstall.sh`, so TCC grants persist).
2. **Release script** (new `release.sh`, extending `reinstall.sh`'s build/sign
   logic). On a version tag it must: bump `MARKETING_VERSION` +
   `CURRENT_PROJECT_VERSION` in `project.yml`; build Release; sign (inside-out, as
   above); zip the `.app`; run Sparkle's `sign_update <zip>` to get the
   `sparkle:edSignature`; run `generate_appcast` to update `appcast.xml`; and
   produce the artifacts to upload. **[MAINTAINER]** uploads the `.zip` to the
   GitHub Release and publishes `appcast.xml`.
3. **Appcast hosting** (recommended): commit `appcast.xml` under `docs/` and
   enable **GitHub Pages** from `docs/` on the default branch → served at
   `https://superluis0.github.io/Oatmeal/appcast.xml` (HTTPS, which Sparkle
   requires). The appcast's `<enclosure url=...>` points at the release `.zip`
   asset URL. (Alternative: a `raw.githubusercontent.com` URL to `appcast.xml` —
   note it in the script but prefer Pages.)
4. **End-to-end test (the real verification).** **[MAINTAINER]**, with the keys
   in place: produce a build at version N, install it; then produce a build at
   N+1, publish a test appcast + zip (can be a local HTTPS server or a draft
   release); in the N app, run "Check for Updates…" and confirm Sparkle: finds
   N+1, verifies the EdDSA signature, downloads, swaps the bundle in
   `~/Applications`, and relaunches. **Then confirm Microphone + Screen-Recording
   grants survived** (record a 5-second meeting without a re-prompt) — this proves
   the same-identity signing worked. If a re-prompt appears, the release was
   signed with the wrong identity — STOP and fix the signing step.

**Verify (Phase 3)**: the end-to-end update installs N+1 over N in one click,
EdDSA verification passes, and TCC permissions persist (no re-prompt).

## Test plan

- Sparkle's verification (EdDSA signature + version comparison) is the security-
  critical path; it is exercised by the Phase 3 end-to-end test, which is the
  primary gate.
- If plan 001 (test target) has landed: add a unit test for any pure mapping you
  introduce (e.g. `SUAppcastItem` → `Release`), and keep a test for the existing
  `UpdateChecker.isNewer(_:than:)` semver comparison if you retain it.
- No automated test can replace the manual Phase 3 run (it needs real signing +
  a real download/swap/relaunch).

## Done criteria

Phase 1 (in-app):
- [ ] Sparkle pinned exactly in `project.yml`; build succeeds; "Check for
      Updates…" menu item present.

Phase 2 (keys + UI):
- [ ] `Info.plist` has `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`.
- [ ] `UpdateChecker` is driven by Sparkle (no `api.github.com` call remains in it);
      the sidebar pill triggers Sparkle's install flow, not just a web link.

Phase 3 (release + proof):
- [ ] A repeatable release script signs with `Oatmeal Self-Signed`, EdDSA-signs,
      and updates `appcast.xml`; appcast served over HTTPS.
- [ ] End-to-end: N→N+1 installs in one click, signature verified, **and TCC
      grants persist (no permission re-prompt)**.
- [ ] `plans/README.md` status row updated (note phases completed).

## STOP conditions

Stop and report (do not improvise) if:
- The dependency-safety gate isn't cleared (unconfirmed/too-new Sparkle version).
- A release build would be signed with anything other than `Oatmeal Self-Signed`
  — this silently breaks every user's Mic/Screen-Recording grants. Never proceed
  with a different identity on the self-signed path.
- Sparkle's nested helpers can't be signed cleanly with the inside-out approach
  (report; `--deep` is not an acceptable shortcut here).
- The Phase 3 update triggers a permission re-prompt — the signing identity is
  wrong; fix before shipping.
- Any step requires the EdDSA **private** key or a real GitHub release that you
  (the executor) cannot perform — STOP and hand back to **[MAINTAINER]** with the
  exact command/inputs needed.

## Maintenance notes

- **Every** future release MUST be signed with `Oatmeal Self-Signed` and
  EdDSA-signed with the same private key, or updates break (TCC re-prompt /
  signature mismatch). Bake this into the release script so it can't be skipped.
- First-time installs from the website still hit Gatekeeper ("unidentified
  developer") because the app isn't notarized — that's the accepted Path B
  tradeoff; in-app Sparkle updates are unaffected (Sparkle strips quarantine).
  Document the right-click→Open first-run step in the README.
- **Upgrade path to Path A**: adopting a Developer ID + notarization later means
  changing only the *signing/notarize* steps in the release script (and removing
  the first-run Gatekeeper friction). The in-app Sparkle wiring from Phases 1-2
  does not change.
- If Hardened Runtime is ever enabled, Sparkle requires specific entitlements on
  its helper tools — revisit then.
- Keep the `appcast.xml` `minimumSystemVersion` in sync with the deployment
  target (macOS 14).
