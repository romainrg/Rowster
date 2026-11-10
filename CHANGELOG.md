# Changelog

All notable changes to Rowster are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Welcome window: connections in groups, with their engine, environment label and color, and a search field.
- Connection form: paste a URL to fill it, Keychain or ask-every-time password, TLS mode, SSH settings, bootstrap SQL, and a Test button.
- Work window per connection: schema sidebar with a filter, tabs (a single click opens a preview tab), database switcher (⌘K), and the color of the environment on the tab bar.
- Connections that must open read-only (production, or *Open read-only*) refuse every statement that is not a plain read, on the server and in the app.
- Data grid: 300 rows per page by default, multi-column sort remembered per table (shift-click adds a column), column widths remembered, estimated and exact row counts, BLOBs shown by their size.
- Copy a cell, or rows as tab-separated text, CSV, JSON, Markdown or `INSERT` statements.
- Filter bar (⌘F): column, operator and value rows combined with AND or OR, a search across every column, a hand-written SQL condition, and *Show SQL*. No limit on the number of filters.
- Row inspector (⌥⌘I): every value of the selected row, a foldable tree for JSON, and binary values loaded on demand as an image or a hex dump.
- Foreign keys: an arrow in the cell opens the referenced row, and hovering it previews that row.
- Unlock writing on a read-only connection for one window at a time, after a confirmation and, optionally, Touch ID; lock it again with one click.
- `DROP`, `TRUNCATE`, and `DELETE` or `UPDATE` without `WHERE` are shown in full and must be confirmed before they run.
- Settings: Touch ID for unlocking, rows fetched per statement, statement history.
- Pending changes: edit cells, add, duplicate and delete rows in the grid; the changes are highlighted and nothing is sent until you preview the exact SQL (⇧⌘P) and commit (⌘S). A commit is one transaction: if a statement fails, or does not change exactly one row, everything is rolled back.
- SQLite connections.
- Demo mode (`--demo`): sample connections on an in-memory database, with no network, disk or Keychain access.
- English and French.
