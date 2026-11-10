# Architecture

This document explains how Rowster is built: its layers, how data flows, and the safety model. Read it before changing a driver, the session or anything that writes. Commands and contribution rules are in [CONTRIBUTING.md](../CONTRIBUTING.md) and [AGENTS.md](../AGENTS.md). The scope of each version is in [specs/](specs/).

## Overview

- **Platform**: macOS 14 or later, universal binary, not sandboxed (SSH tunnels run through the system OpenSSH and read `~/.ssh`), hardened runtime, ad hoc signed.
- **Stack**: Swift in Swift 5 language mode, SwiftUI with AppKit for the data grid and the SQL editor. Apple frameworks only, plus the SDK's `libsqlite3` and `/usr/bin/ssh`.
- **Project**: `project.yml` (XcodeGen) generates `Rowster.xcodeproj`. All logic lives in a local Swift package, `RowsterCore`, which has no SwiftUI or AppKit and is tested without a host app.
- **Pattern**: MVVM with `@Observable`. Services are reached through `AppEnvironment`, which has a live and a demo variant.

## Layers

| Layer | Location | Responsibility |
|---|---|---|
| Core | `RowsterCore/Sources/RowsterCore` | SQL tokenizer, splitter, classifier, dialects, builders, drivers, transport, SSH, connections, session |
| App | `Rowster/App` | `AppEnvironment`, windows |
| Features | `Rowster/Features/<Area>` | One view and one view model per area |
| Shared views | `Rowster/Shared` | Theme, data grid, SQL editor |
| Demo | `Rowster/Demo` | Sample database and demo implementations of every service |
| Screenshots | `Tools/Screenshots` | Offscreen renderer for the README images; never shipped |

This document grows with each increment of [plans/0.1.md](plans/0.1.md).

## Localization

A single String Catalog, `Rowster/Resources/Localizable.xcstrings`, English as the source and French complete. Keys are added to the catalog by hand; `make check-strings` fails when a key is missing or has no French value.

## Distribution

`scripts/build-release.sh` builds a universal Release app, re-signs it ad hoc with the hardened runtime, and writes the DMG, the PKG and `SHA256SUMS` to `build/release/`. See [RELEASING.md](RELEASING.md).
