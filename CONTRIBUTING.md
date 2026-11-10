# Contributing to Rowster

Thanks for your interest in Rowster! This guide explains how to set up the project, the rules every change follows, and how pull requests are reviewed.

By taking part, you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Ways to contribute

- **Report a bug**: open an issue with the *Bug report* template, after checking that it has not been reported already. Reports with other server versions and PostgreSQL-compatible servers are especially welcome.
- **Suggest a feature**: open an issue with the *Feature request* template. For anything bigger than a small fix, discuss it in an issue **before** writing code, so we agree on the approach first.
- **Fix or build something**: issues labeled `good first issue` and `help wanted` are good starting points. Comment on the issue to say you are working on it.
- **Translate the app**: see [Adding a language](#adding-a-language).
- **Report a security issue privately**, never in a public issue: see [SECURITY.md](SECURITY.md).

## Development setup

Requirements: macOS 14 or later, Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
git clone https://github.com/<your-account>/Rowster.git
cd Rowster
make build      # generates Rowster.xcodeproj from project.yml, then builds
make run        # opens the app
```

| Task | Command |
|---|---|
| Generate the Xcode project | `make generate` |
| Build (Debug) | `make build` |
| All tests, then the strings check | `make test` |
| Core tests only (faster) | `make core-test` or `make core-test FILTER=StatementSplitterTests` |
| Tests against local servers | `make integration` |
| Check French translations | `make check-strings` |
| Run with the sample database, no network | `make demo` |
| Render the README scenes | `make screenshots` |
| Universal DMG and PKG | `make release` |

Good to know:

- `project.yml` is the source of truth. Run `make generate` again after adding, removing or renaming a file. Never commit `Rowster.xcodeproj` and never edit `Rowster/Resources/Info.plist`: both are generated.
- The `Makefile` finds Xcode when `xcode-select` points to the Command Line Tools.
- Development builds are signed ad hoc, and macOS ties Keychain items to the exact build: after a rebuild, macOS asks again before Rowster reads a saved password. `make demo` never touches the Keychain.
- `make integration` expects PostgreSQL and MySQL (or MariaDB) installed with Homebrew and listening on localhost; a test whose server is missing is skipped. It never runs in CI.
- **Never test against a production database.**

## Project structure

| Path | Contents |
|---|---|
| `RowsterCore/` | Swift package with all the logic: SQL tokenizer, splitter and classifier, dialects, filter and change-set builders, drivers, transport, SSH tunnel, connections, session. No SwiftUI or AppKit. |
| `RowsterCore/Tests/RowsterCoreTests/` | Unit tests (XCTest). SQLite is tested for real, in process. |
| `Rowster/` | The app target: views, view models, `AppEnvironment` (live and demo), shared views, demo data, resources. |
| `Tools/Screenshots/` | Development tool that renders the README images offscreen. |
| `scripts/` | Release, release-notes, strings check, screenshots and icon scripts. |
| `docs/` | Architecture, specifications, plans and release documentation, images. |

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before changing a driver, the session or anything that writes, and the "Feature pattern" in [AGENTS.md](AGENTS.md) before adding a feature.

## Rules for every change

These rules keep Rowster safe, small and maintainable. A change that breaks one of them needs to be discussed in an issue first.

### Safety

- No write without the user seeing the SQL. Grid edits stay pending until previewed and committed in one transaction.
- A production connection opens read-only, on the server and in the client. Destructive statements are confirmed.
- Values are data: identifiers are quoted by the dialect, values are bound parameters, and no SQL is built by concatenating a value.
- Results are bounded and cancellable. Nothing runs by itself on open except introspection and the user's own bootstrap SQL.
- Passwords live in the Keychain only. Credentials, SQL text and results never reach a log.
- No analytics and no network access beyond the configured databases and SSH hosts.
- No third-party dependencies, no new entitlements, no change to the bundle identifier or signing.
- TablePro is AGPL and Rowster is MIT: do not read its code for inspiration and never copy from it.

### Code

- Logic lives in `RowsterCore`, with unit tests. The app target holds UI and macOS integration.
- MVVM with `@Observable`. No new singletons.
- Services are reached through `AppEnvironment`, with a live and a demo implementation, so every feature works in demo mode.
- Swift 5 language mode. The build must stay free of warnings. 4-space indentation, `// MARK: -` sections.
- Comments and documentation are in English. Keep comments minimal.
- Put `#Preview` blocks last in a file (the strings check skips what follows the first one).

### Tests

- Every logic change in `RowsterCore` comes with tests. A bug fix comes with a test that fails without the fix.
- Builders are tested in every dialect with hostile identifiers and values.
- Tests never touch the real Keychain, Touch ID or the network.
- UI changes are checked with the screenshot tool: open the PNGs and look at light, dark and French.

## Adding a language

English is the source language and French is complete. Strings live in a single String Catalog, `Rowster/Resources/Localizable.xcstrings`, shared by the app and by the core types.

1. Run `make generate` and open `Rowster.xcodeproj`.
2. Select `Localizable.xcstrings`, click **+** at the bottom of the language list and pick your language.
3. Translate every key, mind plural variants (`%lld rows`) and keep placeholders such as `%@` and `%lld` intact.
4. Add the language code to `CFBundleLocalizations` in `project.yml` (then `make generate`), and note it in `README.md`, `README.fr.md` and `CHANGELOG.md`.
5. Run `make test`. `make check-strings` currently requires a French value for every key; when you add a language, extend `scripts/check-strings.sh` so the new language is held to the same standard.
6. Render it with `scripts/screenshots.sh build/screenshots --language <code>` to catch truncated labels.

## Commits and branches

- Work on a branch of your fork, created from `main`: `feat/short-description`, `fix/short-description`, `docs/short-description`...
- Write [Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `build:`, `ci:`, `docs:`, `test:` or `chore:`. Use the imperative mood, keep the subject under 72 characters, and reference issues in the body (`Fixes #42`).
- Keep commits focused, and rebase on `main` rather than merging `main` into your branch.

## Pull requests

1. One topic per pull request. Prefer small pull requests and split larger work.
2. Fill in the pull request template, including how you tested and screenshots (light and dark) for any UI change.
3. Make sure `make test` passes and the build has no warnings. CI runs the tests and a universal Release build on every pull request.
4. Add a line to `CHANGELOG.md` under **Unreleased** for any user-visible change.
5. Update the documentation (both READMEs, `docs/`, `AGENTS.md`) when behavior, commands or rules change.
6. Do not change the version number: the maintainer handles releases.

The maintainer reviews every pull request. Questions and change requests are a normal part of review, not a rejection. Pull requests are squash-merged, so their title must be a valid Conventional Commit message.

## AI-assisted contributions

AI coding assistants are welcome. [AGENTS.md](AGENTS.md) gives them the project's commands and rules (Claude Code reads it through `CLAUDE.md`).

- You are responsible for every line you submit: read it, understand it and test it.
- Say in the pull request which tool you used, and for what.
- Do not submit unreviewed bulk changes, images that do not show the real app, or code you cannot explain.

## Releases

The maintainer publishes releases by pushing a `vX.Y.Z` tag: see [docs/RELEASING.md](docs/RELEASING.md).

## License

By contributing, you agree that your contributions are released under the [MIT License](LICENSE).
