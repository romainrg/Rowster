# Architecture

This document explains how Rowster is built: its layers, how a statement travels, and the safety model. Read it before changing a driver, the session or anything that writes. Commands and contribution rules are in [CONTRIBUTING.md](../CONTRIBUTING.md) and [AGENTS.md](../AGENTS.md). The scope of each version is in [specs/](specs/).

## Overview

- **Platform**: macOS 14 or later, universal binary, not sandboxed (SSH tunnels run through the system OpenSSH and read `~/.ssh`), hardened runtime, ad hoc signed.
- **Stack**: Swift in Swift 5 language mode, SwiftUI with AppKit for the data grid and the SQL editor. Apple frameworks only, plus the SDK's `libsqlite3` and `/usr/bin/ssh`.
- **Project**: `project.yml` (XcodeGen) generates `Rowster.xcodeproj`. All logic lives in a local Swift package, `RowsterCore`, which has no SwiftUI or AppKit and is tested without a host app.
- **Pattern**: MVVM with `@Observable`. Services are reached through `AppEnvironment`, which has a live and a demo variant.

## Layers

| Layer | Location | Responsibility |
|---|---|---|
| Core | `RowsterCore/Sources/RowsterCore` | SQL tokenizer, splitter, classifier, dialects, builders, drivers, transport, SSH, connections, session, export, history |
| App | `Rowster/App` | `AppEnvironment`, windows, settings, the askpass entry point |
| Features | `Rowster/Features` | `Welcome` (connections), `Workspace` (window, sidebar, tabs, data tab), `Editor` |
| Shared views | `Rowster/Shared` | Theme, `DataGrid` (`NSTableView`), `SQLEditorView` (`NSTextView`, TextKit 2) |
| Demo | `Rowster/Demo` | Sample connections and database, demo driver |
| Screenshots | `Tools/Screenshots` | Offscreen renderer for the README images; never shipped |

## Core modules

| Folder | Contents |
|---|---|
| `Values/` | `SQLValue`, `ColumnInfo`, `JSONValue` (keeps key order), `BinaryPreview` |
| `SQL/` | `SQLTokenizer`, `StatementSplitter`, `StatementClassifier`, `SQLHighlighter`, one `SQLDialect` per engine |
| `Builders/` | `BrowseQuery`, `FilterBuilder`, `ChangeSet` |
| `Drivers/` | `DatabaseDriver` and `ResultCursor`; `SQLite/`, `Postgres/`, `MySQL/` |
| `Transport/` | `ByteStream` on `NWConnection`, with the TLS upgrade inside the protocol; `ByteReader` |
| `SSH/` | `SSHTunnel` (one `ssh -N -L <unix-socket>` process), `AskpassServer` and `AskpassClient` |
| `Connections/` | `ConnectionProfile`, `ConnectionStore`, `ConnectionURL`, `SecretStore`, `DriverProviding` |
| `Session/` | `Session`, `ViewStateStore` |
| `Export/`, `History/` | CSV and JSON writers, clipboard formats, statement history and its redaction |

## How a statement travels

1. A view model asks its `Session`. It never talks to a driver.
2. `Session` classifies the statement. On a read-only session anything that is not a plain read is refused before it is sent, including what the classifier does not recognise and what would lift the read-only setting. A destructive statement is refused unless the caller says the user confirmed it.
3. The primary connection runs one statement at a time. Rows come back through a `ResultCursor`, pulled in batches, so reading stops at the limit and memory stays bounded.
4. Introspection, previews and counts use a second, **auxiliary** connection that is always read-only, so a long statement never blocks the sidebar.

`Session.commit` runs the statements of a `ChangeSet` in one transaction and requires each to affect exactly one row; otherwise it rolls everything back.

When the connection drops, the session reconnects (the tunnel too, if it died), applies the read-only state and the bootstrap SQL again, and runs the statement again **only** if it is a plain read outside a transaction.

## Drivers

| | PostgreSQL | MySQL / MariaDB | SQLite |
|---|---|---|---|
| Transport | `ByteStream`, TLS after `SSLRequest` | `ByteStream`, TLS after the greeting | `libsqlite3` on a private queue |
| Authentication | SCRAM-SHA-256, MD5, clear text over TLS | `caching_sha2_password`, `mysql_native_password` | — |
| Statements | Extended protocol, always | Text protocol without parameters, prepared statements with | `sqlite3_prepare_v2` |
| Stopping at the limit | Row count on the portal, then `Close` | Read the rest when short, else `KILL QUERY` | Stop stepping |
| Cancel | `CancelRequest` on its own connection | `KILL QUERY` on its own connection | `sqlite3_interrupt` |

TLS starts inside each protocol, after a clear-text exchange. `ByteStream` does that with an `NWProtocolFramer` that runs the exchange and then prepends TLS to the connection. Certificates are checked according to the connection's TLS mode; through an SSH tunnel the name checked is still the database host.

Code that parses what a server sent goes through `ByteReader`, which never traps on short or malformed input.

## SSH tunnels

Rowster starts `/usr/bin/ssh -N -L <socket>:host:port` once per window, with the socket in a private directory. Every connection of the window goes through that socket, so the user authenticates once and database TLS works through the tunnel. OpenSSH does everything else: `~/.ssh/config`, agents, ProxyJump, known hosts.

Questions from OpenSSH come through `SSH_ASKPASS`. The helper is the Rowster executable itself: started with `ROWSTER_ASKPASS_SOCKET` in its environment, it forwards the question to the running app over a private Unix socket, prints the answer and exits. Answers are never stored or logged.

Hosts, users and targets that could be read as an option are refused before `ssh` is started.

## Live and demo environments

`AppEnvironment.live()` wires the real services. `AppEnvironment.demo()` (launch argument `--demo`, `make demo`) uses an in-memory connection list and secret store, a driver provider that only opens a shared in-memory SQLite database filled with sample data, and no tunnel provider. Every feature must work in both. Screenshots are built from the demo environment, so no real data appears in them.

## Safety model

- **No write without seeing the SQL.** Grid edits are held by `TableTabModel` as pending changes. `ChangeSet` turns them into statements; the preview shows them; `Session.commit` runs them in one transaction.
- **Values are data.** Builders take values and return `SQLFragment`s: SQL text with placeholders, and the values beside it. `literalForDisplay` and `inlinedForDisplay` write values into text for the preview and the clipboard only.
- **Read-only is applied twice**: on the server session, and by the classifier in `Session`. It is applied again after a reconnection and fails closed.
- **Secrets** are in the Keychain only. `ConnectionProfile` has no field for one.
- **The history** stores statements, never results, and replaces password literals.

The limits of the read-only mode are stated in [SECURITY.md](../SECURITY.md).

## Localization

A single String Catalog, `Rowster/Resources/Localizable.xcstrings`, English as the source and French complete. Keys are added by hand (`scripts/add-strings.py` helps); `make check-strings` fails when a key is missing or has no French value.

## Distribution

`scripts/build-release.sh` builds a universal Release app, re-signs it ad hoc with the hardened runtime, and writes the DMG, the PKG and `SHA256SUMS` to `build/release/`. See [RELEASING.md](RELEASING.md).
