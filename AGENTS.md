# AGENTS.md

Instructions for AI coding agents (Claude Code, Codex, GitHub Copilot, Cursor, Gemini...) working on Rowster. Humans should read [CONTRIBUTING.md](CONTRIBUTING.md); this file summarizes the same rules in an actionable form.

## Project

Rowster is a free, open-source (MIT) native database client for macOS: PostgreSQL, MySQL/MariaDB and SQLite in 0.1. It aims for the simplicity of the best native clients, with safety built in: no write without seeing the SQL, production opened read-only, bounded and cancellable results. Swift and SwiftUI (AppKit for the data grid and the SQL editor), macOS 14+, universal binary, not sandboxed, no third-party dependencies, English and French.

The scope and design of each version are in `docs/specs/`, the increments in `docs/plans/`.

## Commands

Run them from the repository root. The `Makefile` finds Xcode even when `xcode-select` points to the Command Line Tools. XcodeGen is required (`brew install xcodegen`).

```sh
make generate                             # xcodegen generate; after adding, removing or renaming a file, or editing project.yml
make build                                # Debug build
make test                                 # all tests through xcodebuild, then make check-strings
make core-test                            # RowsterCore tests only, with swift test (faster)
make core-test FILTER=StatementSplitterTests
make integration                          # tests against local PostgreSQL, MySQL and sshd; never run in CI
make check-strings                        # every string the compiler extracted has a French translation in the catalog
make run                                  # build and open the app
make demo                                 # launch with --demo: sample database, no network, no Keychain
make screenshots                          # render the README scenes offscreen into docs/images
make release                              # universal build; writes build/release/Rowster-<v>.dmg, .pkg and SHA256SUMS
make clean
```

`make check-strings` reads the compiler output of the last Debug build: run `make build` first (`make test` does it for you).

## Map

- `project.yml`: XcodeGen spec and source of truth. `Rowster.xcodeproj` and `Rowster/Resources/Info.plist` are generated and git-ignored.
- `RowsterCore/Sources/RowsterCore/`: all the logic, with no SwiftUI or AppKit.
  - `Values/`: `SQLValue`, `ColumnInfo`, `Row`.
  - `SQL/`: tokenizer, `StatementSplitter`, `StatementClassifier`, one `SQLDialect` per engine.
  - `Builders/`: `FilterBuilder`, `BrowseQuery`, `ChangeSet`, `CommitRunner`.
  - `Drivers/`: `DatabaseDriver` and `ResultCursor` protocols; `SQLite/`, `Postgres/`, `MySQL/`.
  - `Transport/`, `SSH/`: `ByteStream` over Network.framework with the in-protocol TLS upgrade; `SSHTunnel` through `/usr/bin/ssh` and the askpass server.
  - `Connections/`: `ConnectionProfile`, `ConnectionStore`, `ConnectionURL`, `SecretStore`, `DriverProviding`.
  - `Session/`: one `Session` per work window (primary and auxiliary connections, read-only state, commit, reconnection), `ViewStateStore`.
  - `Export/`, `History/`.
- `RowsterCore/Tests/RowsterCoreTests/`: XCTest suites. SQLite is tested for real, in process. The `*IntegrationTests` classes only run with `make integration`, against the servers of `scripts/integration-servers.sh start`.
- `Rowster/`: app target. `App/` (`AppEnvironment` live and demo, windows, settings), `Features/Welcome`, `Features/Workspace` (window, sidebar, tabs, data tab, filters, inspector, structure, safety), `Features/Editor`, `Shared/` (theme, `DataGrid`, `SQLEditorView`), `Demo/`, `Resources/`.
- `Tools/Screenshots/`: offscreen renderer for the README images (development only, never shipped); scenes in `Scenes.swift`.
- `scripts/`: release build, release notes, strings check, screenshots, icon.
- `docs/ARCHITECTURE.md`: layers, data flow, safety model. Read it before touching a driver, the session or anything that writes.

## Invariants

Never break these. If a task seems to require it, stop and ask the human.

1. **No write without seeing the SQL.** Edits made in the grid stay pending and highlighted. The SQL preview (⌘⇧P) then the commit (⌘S) run in **one transaction**, rolled back whole on any error. Each generated `UPDATE` or `DELETE` must affect exactly one row.
2. **Production is protected.** A connection labelled *production* opens **read-only**: `SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY` (PostgreSQL), `SET SESSION TRANSACTION READ ONLY` (MySQL/MariaDB), `SQLITE_OPEN_READONLY` and `PRAGMA query_only` (SQLite), plus the client-side `StatementClassifier`, which also refuses what it cannot classify. Read-only is applied on every connection of the session, again after a reconnection, and fails closed. The production color is visible everywhere (title bar, tabs). Unlocking writes needs a confirmation, or Touch ID when enabled, and lasts for the window only.
3. **Destructive statements are confirmed**: `DROP`, `TRUNCATE`, and `DELETE` or `UPDATE` without `WHERE`, with the statement displayed. Nothing runs by itself on open, apart from introspection and the bootstrap SQL the user wrote.
4. **Results are bounded.** Rows are pulled through a `ResultCursor` with a default limit (300 when browsing, configurable in the editor). Cancel always works. A BLOB is loaded only on demand.
5. **Values are data.** The app never builds SQL by concatenating values. Identifiers are quoted by the dialect and values are bound parameters. No API takes a value and returns SQL text to execute.
6. **Secrets.** Passwords are stored only in the Keychain (or asked on each connection). A connection export contains no password. Credentials, SQL text and query results never appear in a log.
7. **Network.** Rowster only contacts the databases and SSH hosts the user configured. Every connection is created by a `DriverProviding` and every tunnel by a `TunnelProviding`: the demo environment has a provider that only opens in-memory SQLite, and no tunnel provider. No telemetry. The AI assistant and the MCP server (later versions) are off by default, enabled per connection; the MCP server listens on localhost only, with a token, read-only by default.
8. **No third-party dependency, no new entitlement, no signing change** without the maintainer's approval. Apple frameworks only, plus the SDK's `libsqlite3` and `/usr/bin/ssh`. Not sandboxed, hardened runtime on, ad hoc signed, bundle identifier `io.github.romainrg.Rowster`.
9. **Clean-room.** TablePro is AGPL: never read its code for inspiration and never copy anything from it.
10. **Demo isolation.** Demo mode goes through `AppEnvironment.demo()` only: an in-memory SQLite sample and fake drivers, never the network, the Keychain or a real database.
11. **Localization.** English is the source language and French is complete. Every user-facing string goes through `Localizable.xcstrings`.
12. **Author hygiene.** Nothing in code, metadata, docs, screenshots or commits mentions an employer or any company. Only "Romain Gallien" and the `romainrg` account appear.
13. **Both READMEs stay in sync**: `README.md` and `README.fr.md` have the same sections in the same order.

## Conventions

- Code comments and documentation in **English**, identifiers in English. Keep comments minimal: code should explain itself.
- Logic and rules in `RowsterCore`; views, view models and macOS integration in `Rowster/`. Views are `@Observable` MVVM, with no new singletons. Services are reached through `AppEnvironment`, set in both `live()` and `demo()`.
- `RowsterCore` imports Foundation, Network, CryptoKit, CommonCrypto, Security, SQLite3, Observation and os, never SwiftUI or AppKit.
- **Strings are added by hand.** xcodebuild does not add new keys to `Localizable.xcstrings`. Add each key in the exact format the compiler extracts (for example `%lld rows`) with a complete French value, then run `make build && make check-strings`. `scripts/add-strings.py` merges `key<TAB>French` lines from standard input into the catalog, and `make check-strings` lists the keys that are still missing.
- **Values a user types** become `SQLValue`s through `SQLValue.typed(_:as:)` and reach the server as bound parameters. `literalForDisplay` and `inlinedForDisplay` exist for the SQL preview and the clipboard only: never execute their output.
- **A `Session` is the only way to run a statement from the app.** It checks the read-only state and destructive statements before anything is sent; do not call a driver directly from a view model.
- Put `#Preview` blocks **last** in a file: `check-strings` ignores strings after the first `#Preview`.
- Zero build warnings. 4-space indentation, `// MARK: -` sections (see `.editorconfig`).
- Conventional Commits: `feat:`, `fix:`, `build:`, `ci:`, `docs:`, `test:`, `chore:`. One branch and one pull request per increment.

## Feature pattern

1. **Core and tests.** Write the logic in `RowsterCore` behind a protocol, with unit tests. Cover the hostile cases of the invariants: identifiers with quotes, backticks, brackets, spaces, emoji and reserved words; values that look like SQL.
2. **`AppEnvironment` service**, set in both `live()` and `demo()`, with the demo implementation in `Rowster/Demo/`.
3. **View model and view** in `Rowster/Features/<Area>/`, built on the `Shared/` components and the theme.
4. **Strings** with French, then `make build && make check-strings`.
5. **Screenshot scene** in `Tools/Screenshots/Scenes.swift`, from demo data. Run `scripts/screenshots.sh build/screenshots <scene>`, **open the PNGs** and check light, dark and French (`--language fr`).
6. **Wrap up**: README features (both languages), `CHANGELOG.md`, `docs/ARCHITECTURE.md`.

## Definition of done

- `make test` passes (unit tests and `make check-strings`) with no warnings.
- Logic changes have unit tests in `RowsterCoreTests`; bug fixes include a regression test that fails without the fix.
- New strings exist in French. UI changes were rendered with the screenshot tool and the PNGs were opened and checked in light, dark and French.
- Never test against a production database. Tests never touch the real Keychain, Touch ID or the network; integration tests only use servers on localhost.
- Do not trigger permission prompts or drive the UI through automation; list manual test steps for the human.
- User-visible changes have an entry under **Unreleased** in `CHANGELOG.md`. Documentation (both READMEs, `docs/`, this file) is updated when commands, behavior or rules change.
- Do not bump versions, create tags, push, create the GitHub repository, or edit the release workflow or signing settings unless explicitly asked, each time.
- Pull requests follow `.github/PULL_REQUEST_TEMPLATE.md`, including the *AI assistance* section.
