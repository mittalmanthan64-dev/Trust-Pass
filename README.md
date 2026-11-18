# OneCampus TrustPass

A local, runnable prototype for the Secure Digital Identity for Campus Services PRD. The app has a separate `frontend/` and `backend/`, and persists data to a local SQLite database.

## Run it

Requirements: Python 3.10 or newer. No package installation is needed.

On Windows, double-click `Start TrustPass.bat` to start the backend and open the app in your browser. Keep the server window open while you use the app.

From the project folder, run:

```powershell
python backend/server.py
```

Then open [http://localhost:8000](http://localhost:8000). The database is created automatically at `backend/data/trustpass.sqlite3` on first launch. Set `PORT` or `TRUSTPASS_DB` before starting the server to use a different local port or database location.

## Demo accounts

The sign-in page displays a fresh six-digit authenticator code for each demo account. Enter the displayed code with either account:

| Role | Email | Password |
| --- | --- | --- |
| Student | `aarav.sharma@northfield.edu` | `CampusDemo!26` |
| Security Admin | `admin@northfield.edu` | `CampusAdmin!26` |

The sample student’s recovery backup code is `A7KP-94QX` (the recovery flow also accepts the other sample codes `M3DV-18TZ`, `R6WB-52JN`, and `H8LC-37PF`). These are demo credentials and must be replaced before any shared deployment.

## What works

- Password and TOTP sign-in, a 12-hour server-side session, sign-out, and progressive role-aware access.
- A signed, 30-second identity pass. It is stored by hash, consumed once, and rejected after expiry or replay.
- Per-service consent controls and attribute minimization for Library, Hostel, Exam Hall, and Campus Gate. A verifier receives only the fields registered by that service.
- Session listing and immediate individual session revocation.
- Append-only activity records linked with SHA-256 hashes, with full-chain verification in the access-history screen.
- Recovery using the demo account password, a one-time backup code, a short cooling-off period, and an email code. Completing recovery revokes all the account’s sessions.
- Admin user list, role changes enforced by the backend, and identity suspension with session revocation.

## Database and prototype limits

This prototype uses SQLite locally so it starts immediately and keeps data between restarts. It is suitable for a single-machine demo. It does not yet implement OIDC authorization-code flow/PKCE, passkey registration, real email delivery, an institutional roster import, production-grade secret management, TLS termination, or a production database migration layer. The rotating pass is a compact signed token used by the in-app verifier; it is not a scannable QR code. Use the feature flows for a prototype demonstration, not real student identities or production campus access.

## If you want a hosted database

For PostgreSQL, provide a hosted provider (for example Supabase, Neon, or a university-managed PostgreSQL instance) and either:

- a PostgreSQL connection URL with SSL enabled, or
- host, port, database name, username, password, and the required SSL mode.

Keep credentials in environment variables or a deployment secret manager; do not commit them. Also tell me where the app will be hosted so I can configure its network access and migrations. No database account or credentials are needed to run the current local demo.

## Layout

```text
frontend/   HTML, CSS, browser application
backend/    Python API server and local SQLite store
```
