# Releases and updates

WattBar 1.1.0 already supports Sparkle. Keep its existing public key and Keychain account (`ed25519`); changing the key would break updates for installed copies. Private keys stay in Keychain, never in Git or CI logs.

## Prepare a release

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the Xcode project. Every release needs a higher build number.
2. Add notes in `ReleaseNotes/`, run `swift test`, then commit and push the source.
3. With a paid Apple Developer membership, set `CODESIGN_IDENTITY` to your Developer ID Application identity and `NOTARY_PROFILE` to a configured notarytool Keychain profile.
4. Run `./release.sh VERSION BUILD_NUMBER ReleaseNotes/VERSION.md`.

Without Developer ID, use the explicit alternative:

```
./release.sh --adhoc 1.3.0 6 ReleaseNotes/1.3.0.md
```

This creates an ad-hoc build that **has not been notarized by Apple**. Gatekeeper may block first launch. Sparkle signing authenticates updates; it does not replace Apple notarization. Do not call an ad-hoc release notarized.

The script builds a universal app, verifies code signatures, signs the final ZIP and feed, checks metadata, keeps prior feed entries, and writes checksums under `build/releases/vVERSION/`. Future notarized builds are submitted and stapled before the final ZIP is signed. Existing release directories and tags cannot be reused.

The one-time migration from 1.1.0 accepts only the SHA-256-pinned original unsigned feed. All subsequent feeds must have a valid Sparkle signature. New versions require signed feeds and validate archive signatures before extraction.

## Verify and publish

Test the packaged app before uploading:

```
Tests/ReleaseScripts/smoke-sparkle.sh
./scripts/publish-release.sh vVERSION
```

The smoke test uses a disposable key, starts Sparkle with the packaged framework, checks feed/archive signatures and tamper rejection, and verifies that older release URLs survive feed regeneration. Publishing uploads a draft pinned to the source commit in the release manifest. Review its notes and assets, then publish it as the latest stable GitHub release.

Installed WattBar 1.1.0 copies check:

`https://github.com/musaAmir/WattBar/releases/latest/download/appcast.xml`

They can update directly to later releases that retain the existing signing key. Older versions without Sparkle need a manual download. Users can disable automatic checks in Preferences and still check manually. New versions are offered for installation; automatic installation is not enabled by default.

Back up the existing Sparkle key securely before replacing this Mac. Consult [Sparkle’s signing documentation](https://sparkle-project.org/documentation/) for manual backup and restore. Do not generate a new key for this existing app.

## Website

The static site lives in `docs/index.html`, `docs/styles.css`, `docs/app.js`, and `docs/assets/`. GitHub Pages publishes changes on pushes to `main` through `.github/workflows/pages.yml`, or via Run workflow. No build service or runtime dependencies are needed. The interactive illustration uses sample values and never reads visitors’ hardware.

Update the versioned download links in `docs/index.html` when publishing a new release. Keep those links on the currently published version while preparing and pushing source for the next release, so website deployments never point to an unavailable archive.

### Hardware checks before a wider rollout

Verify battery charging/held charge/discharging on a MacBook, plug/unplug and sleep/wake transitions, login-item approval, and an Intel Mac where available. These cannot be fully exercised on this desktop Mac. See the release notes for checks completed for each version.
