# Releasing

Rowster follows [Semantic Versioning](https://semver.org). The version lives in `project.yml`: `MARKETING_VERSION` (for example `0.2.0`) and the build number `CURRENT_PROJECT_VERSION`.

## Publishing a release

1. On a branch from `main`, move the **Unreleased** entries of `CHANGELOG.md` under a new `## [X.Y.Z] - YYYY-MM-DD` heading and update the comparison links at the bottom of the file.
2. In `project.yml`, set `MARKETING_VERSION` to `X.Y.Z` and increment `CURRENT_PROJECT_VERSION`.
3. Check locally:

   ```sh
   make test                         # unit tests and strings check
   make release                      # universal build, signature checks, DMG, PKG and SHA256SUMS in build/release/
   scripts/release-notes.sh X.Y.Z    # notes that will be published
   ```

   `make release` fails unless the binary is universal (arm64 and x86_64) and the ad hoc signature carries the hardened runtime flag. Open the DMG and the PKG once and run `shasum -a 256 -c SHA256SUMS` from `build/release/`.

4. Commit (`chore: release X.Y.Z`), open a pull request and merge it once CI passes.
5. Tag the merge commit and push the tag:

   ```sh
   git switch main && git pull
   git tag -a vX.Y.Z -m "Rowster X.Y.Z"
   git push origin vX.Y.Z
   ```

6. The **Release** workflow (`.github/workflows/release.yml`) checks that the tag matches `MARKETING_VERSION`, runs the tests, builds the universal app and publishes a GitHub release with `Rowster-X.Y.Z.dmg`, `Rowster-X.Y.Z.pkg`, `SHA256SUMS` and the changelog notes.

If the workflow fails, fix the problem on `main`, delete the tag (`git push --delete origin vX.Y.Z` and `git tag -d vX.Y.Z`), then tag again.

## Signing

Release builds are signed **ad hoc** with the hardened runtime and are not notarized: they run on any Mac, but Gatekeeper blocks the first open until the user clicks **Open Anyway** (System Settings > Privacy & Security), and macOS ties Keychain items to the exact build, so it asks again for access to each saved password after an update. The README explains both to users.

## Planned distribution channels

None of these is set up yet; each requires a paid Apple Developer Program membership.

- **Developer ID signing and notarization** of the GitHub releases, which removes the Gatekeeper warning and the Keychain prompts after updates.
- **Homebrew cask**, once releases are notarized.
- **Mac App Store**: needs its own design (sandbox, reduced feature set).
