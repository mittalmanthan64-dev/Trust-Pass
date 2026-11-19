# OneCampus TrustPass

A cross-platform, runnable prototype for the Secure Digital Identity for Campus Services PRD. It has separate `frontend/` and `backend/` folders, uses SQLite locally by default, and can use Supabase for shared data.

## Run it

Requirements: Python 3.10 or newer. No package installation is needed.

On Windows, double-click `Start TrustPass.bat`. On macOS, run `chmod +x "Start TrustPass.command"` once in Terminal if the synced file isn't marked executable, then double-click it. Keep the server window open while using the app. Both launchers check for an existing TrustPass server before starting another one.

From the project folder, run:

```powershell
python backend/server.py
```

Then open [http://localhost:8000](http://localhost:8000). The database is created automatically at `backend/data/trustpass.sqlite3` on first launch. Set `PORT` or `TRUSTPASS_DB` before starting the server to use a different local port or database location.

## Open it on another device on the same Wi-Fi

The default server only accepts connections from this computer. For a temporary demo on a trusted private Wi-Fi network, use `Start TrustPass LAN.bat` on Windows or `Start TrustPass LAN.command` on macOS. On macOS, run `chmod +x "Start TrustPass LAN.command"` once if needed. Both launchers start the server for other devices on the local network. On Windows, run `ipconfig` and use the private IPv4 address shown with port `8000`; on macOS, the launcher prints the Wi-Fi address. Enter `http://<computer-ip>:8000` on the other device.

If the operating system asks about the firewall, allow Python only on a private network you trust. This demo uses plain HTTP and published sample credentials: use fictional records only, and do not expose it to the public internet.

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

## Database setup

The Supabase project `pfixtpslguysgqebfeej` has the TrustPass schema applied. The initial identity schema is in `supabase/schema.sql`; the private app store used by this demo is in `supabase/app_store.sql`. The app store holds the demo accounts, sessions, service consents, passes, recovery records, backup-code hashes, sign-in lockouts, and audit trail. It lives in Supabase's `private` schema and is accessible only to the backend database connection. All 15 public and 8 private tables have row-level security enabled; browser roles cannot access the private tables.

By default, Windows and Mac use the local SQLite file. To use Supabase locally, copy `.env.example` to `.env`, then set `DATABASE_URL` to the **Transaction pooler** connection string from Supabase Dashboard → **Connect** (port `6543`). Set a long random `TRUSTPASS_SIGNING_KEY` as well. Install the optional Supabase driver with `python -m pip install -r requirements.txt`. The backend switches to Supabase automatically when `DATABASE_URL` is present; it never sends the database password to the browser. Keep `.env` private and do not commit it.

On first connection, the backend creates the two fictional demo accounts and their sample consent/recovery records in the private Supabase tables. Sign-ins, sessions, consent changes, passes, recovery, and audit entries then persist in Supabase. These are prototype accounts with public demo credentials; replace/remove them before using real campus identities.

## Vercel setup

The repository includes a Vercel entry point for the existing API and serves `frontend/` as the static site. In Vercel, import the repository with the project root set to the repository root. Before deploying, add these environment variables for Preview and Production:

| Name | Value |
| --- | --- |
| `DATABASE_URL` | Supabase **Transaction pooler** connection string (port `6543`) with the database password filled in |
| `TRUSTPASS_SIGNING_KEY` | A long random secret that stays the same across deployments |

The Vercel API requires `DATABASE_URL` and `TRUSTPASS_SIGNING_KEY`; it does not fall back to temporary SQLite storage. The backend requires the `psycopg` dependency listed in `requirements.txt`. Python is pinned to 3.13 for the Vercel runtime. Never put either secret in frontend code or Git. Supabase recommends transaction mode for serverless functions; copy the exact connection string from the Dashboard rather than constructing the host yourself, and URL-encode special characters in the database password.

This remains a demo deployment until the public demo credentials and demo-account display are removed and the app is switched to real Supabase Auth. Do not enter real student data into it.

## Layout

```text
frontend/   HTML, CSS, browser application
backend/    Python API server with local SQLite or Supabase storage
```
