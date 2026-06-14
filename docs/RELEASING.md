# Releasing Oatmeal (one-click updates via Sparkle)

Oatmeal ships in-app updates with [Sparkle](https://sparkle-project.org). Existing
installs check a signed *appcast* and can download + install a new version in one
click. This is the **self-signed** distribution path: every release is signed with
the stable `Oatmeal Self-Signed` certificate and authenticated with an EdDSA
signature.

## One-time setup

1. **Signing certificate** — run `./reinstall.sh` once. It creates the stable
   `Oatmeal Self-Signed` code-signing identity in your login Keychain
   (idempotent). Every release MUST use this identity (see the warning below).
2. **EdDSA key** — already generated; the public half lives in
   `Oatmeal/Info.plist` (`SUPublicEDKey`) and the private half is in your login
   Keychain (created by Sparkle's `generate_keys`). If you ever need to recreate
   it, run `generate_keys` from the Sparkle package's `bin/` and update
   `SUPublicEDKey`. **Back up the private key** (`generate_keys -x key.priv`,
   stored offline) — losing it means existing installs can no longer verify
   updates and must be reinstalled manually.
3. **GitHub Pages** — in the repo Settings → Pages, deploy from branch `main`,
   folder `/docs`. The appcast is then served at
   `https://superluis0.github.io/Oatmeal/appcast.xml` (the URL in
   `Info.plist`'s `SUFeedURL`).

> ⚠️ **Never sign a release with any other identity.** macOS ties the
> Microphone and Screen-Recording permission grants to the app's signing
> identity. A release signed with a different cert (or ad-hoc) makes every user
> re-grant permissions after updating. `release.sh` enforces `Oatmeal Self-Signed`
> and aborts if it's missing.

## Cutting a release

1. Bump the version in `project.yml`:
   - `MARKETING_VERSION` (e.g. `0.5.0`) — the user-visible version.
   - `CURRENT_PROJECT_VERSION` (e.g. `5`) — must increase every release; Sparkle
     compares this (`CFBundleVersion`) to decide what's newer.
2. Run the pipeline:
   ```bash
   ./release.sh
   ```
   It builds a **universal** Release (arm64 + x86_64), signs it inside-out with
   `Oatmeal Self-Signed`, zips it with `ditto`, EdDSA-signs the archive, and
   updates `docs/appcast.xml`. Artifacts land in `dist/` (gitignored).
3. Publish:
   ```bash
   # upload the signed zip as the release asset for this tag
   gh release create v0.5.0 dist/Oatmeal-0.5.0.zip --title "Oatmeal 0.5.0" --notes "…"
   # commit the updated feed
   git add docs/appcast.xml && git commit -m "Release 0.5.0" && git push
   ```
   The appcast's `<enclosure url>` points at
   `https://github.com/superluis0/Oatmeal/releases/download/v<VERSION>/Oatmeal-<VERSION>.zip`,
   so the tag and asset filename must match what `release.sh` printed.

Existing installs pick up the update on their next scheduled check (or via
**Oatmeal → Check for Updates…**).

## Verifying an update end-to-end (recommended before announcing)

1. Keep a copy of the *current* installed version running.
2. Cut the new version, upload the asset, push the appcast, confirm Pages serves
   it (`curl https://superluis0.github.io/Oatmeal/appcast.xml`).
3. In the old version: **Check for Updates…** → confirm Sparkle finds it,
   verifies the signature, downloads, installs, and relaunches.
4. **Confirm permissions survived**: record a 5-second meeting without any
   Microphone/Screen-Recording re-prompt. A re-prompt means the release was
   signed with the wrong identity — do not announce; rebuild with
   `Oatmeal Self-Signed`.

## Notes & gotchas

- **First install is still Gatekeeper-gated.** Because the app isn't notarized
  (Path B), a *freshly downloaded* zip is quarantined; first-run requires
  right-click → Open. In-app Sparkle updates are unaffected (Sparkle removes the
  quarantine flag on installs it performs).
- **`generate_appcast` merges.** It preserves existing `<item>`s and adds the new
  one, so old versions stay in the feed. If you re-cut the *same* version with
  different contents, delete that item (or `docs/appcast.xml`) and regenerate so
  fields like `hardwareRequirements` recompute.
- **Universal builds.** `release.sh` forces `ARCHS="arm64 x86_64"` so Intel Macs
  are served too. If you ever drop Intel support, remove that and the appcast
  will carry an `arm64` hardware requirement automatically.
- **Upgrading to notarization (Path A) later** only changes the signing steps in
  `release.sh` (Developer ID + `xcrun notarytool` + staple) and removes the
  first-run Gatekeeper friction. The in-app Sparkle wiring does not change.
