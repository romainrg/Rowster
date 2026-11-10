# Security policy

Rowster connects to databases, stores their passwords in the Keychain and can write to production data, so security and safety reports are taken seriously.

## Supported versions

Only the [latest release](https://github.com/romainrg/Rowster/releases/latest) receives security fixes.

## Reporting a vulnerability

**Please do not open a public issue.** Report the problem privately through GitHub: [report a vulnerability](https://github.com/romainrg/Rowster/security/advisories/new) (Security tab > Advisories).

Please include:

- the Rowster and macOS versions, the database engine and its version;
- a description of the problem and its impact;
- the steps to reproduce it, or a proof of concept;
- whether the problem is already public.

Rowster is maintained on a volunteer basis. You can expect an acknowledgement within 7 days and an assessment within 30 days. You will be kept informed, credited in the release notes if you wish, and consulted on the disclosure date once a fix is available.

## Scope

In scope, for example:

- a write reaching a database without the user having seen the SQL, or outside the single commit transaction;
- a write getting through on a connection opened read-only, without the user unlocking it;
- a value from the grid, a filter, a file or a database being interpreted as SQL, as a shell argument or as an `ssh` option;
- a password, a passphrase or query results written to a log, a file or an export;
- a network connection to anything other than the configured database and SSH hosts;
- a certificate accepted in the *Verify CA* or *Verify identity* TLS modes when it should not be.

Out of scope:

- attacks that require an already compromised user account or administrator access;
- the Gatekeeper warning shown on first launch of builds that are not notarized;
- the limits listed below.

## Known limits of the read-only mode

Read-only is enforced twice: by the server session (`READ ONLY` transactions, `query_only`) and by a client-side statement classifier. It protects against accidents. It is not a boundary against the person at the keyboard, who can unlock writing, and a read-only transaction does not prevent every side effect on the server: functions such as `pg_terminate_backend` or `nextval` still run. The strong guarantee is a database role without write privileges.

## Distribution

Release builds are signed **ad hoc** and are not notarized. Verify a download against the `SHA256SUMS` file published with each release (`shasum -a 256 -c SHA256SUMS`).

Because an ad hoc signature has no stable identity, macOS asks again for access to each saved password after an update. Developer ID signing and notarization are on the [roadmap](README.md#roadmap).
