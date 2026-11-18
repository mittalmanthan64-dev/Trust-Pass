"""OneCampus TrustPass demo API. Uses only the Python standard library."""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import secrets
import sqlite3
import struct
import time
from datetime import datetime, timezone
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
DB_PATH = Path(os.environ.get("TRUSTPASS_DB", Path(__file__).parent / "data" / "trustpass.sqlite3"))
PORT = int(os.environ.get("PORT", "8000"))
SIGNING_KEY = os.environ.get("TRUSTPASS_SIGNING_KEY", "local-demo-signing-key-change-before-deploy").encode()
DB_PATH.parent.mkdir(parents=True, exist_ok=True)
LOGIN_FAILURES: dict[str, tuple[int, int]] = {}

SERVICES = [
    {"id": "library", "name": "Library", "kind": "Books & study", "description": "Confirm active student status for borrowing privileges.", "attributes": ["is_enrolled"], "purpose": "Confirm eligibility to borrow books", "color": "mint"},
    {"id": "hostel", "name": "Hostel", "kind": "Housing", "description": "Check resident status for building access.", "attributes": ["full_name", "hostel_resident"], "purpose": "Confirm resident access at the building", "color": "violet"},
    {"id": "exams", "name": "Exam Hall", "kind": "Examinations", "description": "Verify exam registration with your roll number.", "attributes": ["full_name", "roll_number", "is_enrolled"], "purpose": "Match your exam registration", "color": "amber"},
    {"id": "gate", "name": "Campus Gate", "kind": "Campus access", "description": "Check campus entry eligibility.", "attributes": ["is_enrolled"], "purpose": "Verify current campus access", "color": "blue"},
]
ATTRIBUTES = {"is_enrolled": "Currently enrolled", "full_name": "Full name", "roll_number": "Enrollment number", "program": "Program of study", "hostel_resident": "Hostel resident status"}


def connect():
    con = sqlite3.connect(DB_PATH)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA foreign_keys = ON")
    return con


def now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def password_hash(password: str, salt: bytes | None = None) -> str:
    salt = salt or secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, 310_000)
    return f"{base64.urlsafe_b64encode(salt).decode()}${base64.urlsafe_b64encode(digest).decode()}"


def password_ok(password: str, saved: str) -> bool:
    try:
        salt64, digest64 = saved.split("$", 1)
        salt = base64.urlsafe_b64decode(salt64)
        expected = base64.urlsafe_b64decode(digest64)
        actual = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, 310_000)
        return hmac.compare_digest(expected, actual)
    except Exception:
        return False


def totp(secret: str, at: int | None = None) -> str:
    counter = int((at if at is not None else time.time()) // 30)
    key = base64.b32decode(secret + "=" * ((8 - len(secret) % 8) % 8))
    digest = hmac.new(key, struct.pack(">Q", counter), hashlib.sha1).digest()
    offset = digest[-1] & 15
    value = (struct.unpack(">I", digest[offset:offset + 4])[0] & 0x7fffffff) % 1_000_000
    return f"{value:06d}"


def add_audit(con, actor, action, target, service="TrustPass", details=""):
    previous = con.execute("SELECT entry_hash FROM audit ORDER BY id DESC LIMIT 1").fetchone()
    prev_hash = previous[0] if previous else "0" * 64
    created = now()
    payload = "|".join((created, str(actor or "system"), action, str(target), service, details, prev_hash))
    entry_hash = hashlib.sha256(payload.encode()).hexdigest()
    con.execute("INSERT INTO audit(created_at, actor, action, target, service, details, previous_hash, entry_hash) VALUES(?,?,?,?,?,?,?,?)",
                (created, actor or "system", action, str(target), service, details, prev_hash, entry_hash))


def init_db():
    with connect() as con:
        con.executescript("""
        CREATE TABLE IF NOT EXISTS users(id TEXT PRIMARY KEY, email TEXT UNIQUE NOT NULL, name TEXT NOT NULL, role TEXT NOT NULL, password_hash TEXT NOT NULL, otp_secret TEXT NOT NULL, roll_number TEXT NOT NULL, program TEXT NOT NULL, year INTEGER NOT NULL, hostel INTEGER NOT NULL DEFAULT 0, active INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), token_hash TEXT NOT NULL UNIQUE, device TEXT NOT NULL, created_at TEXT NOT NULL, last_seen TEXT NOT NULL, expires_at INTEGER NOT NULL, revoked INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS consents(user_id TEXT NOT NULL REFERENCES users(id), service_id TEXT NOT NULL, granted INTEGER NOT NULL, updated_at TEXT NOT NULL, PRIMARY KEY(user_id,service_id));
        CREATE TABLE IF NOT EXISTS passes(jti_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), expires_at INTEGER NOT NULL, used INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS audit(id INTEGER PRIMARY KEY AUTOINCREMENT, created_at TEXT NOT NULL, actor TEXT NOT NULL, action TEXT NOT NULL, target TEXT NOT NULL, service TEXT NOT NULL, details TEXT NOT NULL, previous_hash TEXT NOT NULL, entry_hash TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS recovery(id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), code_hash TEXT NOT NULL, expires_at INTEGER NOT NULL, cooling_until INTEGER NOT NULL, used INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS backup_codes(user_id TEXT NOT NULL REFERENCES users(id), code_hash TEXT NOT NULL, used INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(user_id,code_hash));
        """)
        if not con.execute("SELECT 1 FROM users LIMIT 1").fetchone():
            con.execute("INSERT INTO users VALUES(?,?,?,?,?,?,?,?,?,?,?,?)", ("usr_student_01", "aarav.sharma@northfield.edu", "Aarav Sharma", "Student", password_hash("CampusDemo!26"), "JBSWY3DPEHPK3PXP", "EN2023CS001", "B.Tech Computer Science", 3, 1, 1, now()))
            # A separate staff identity demonstrates role-aware administrative access.
            con.execute("INSERT INTO users VALUES(?,?,?,?,?,?,?,?,?,?,?,?)", ("usr_admin_01", "admin@northfield.edu", "Mira Patel", "Security Admin", password_hash("CampusAdmin!26"), "KRSXG5DSNFXGOIDB", "STAFF-0042", "Campus Security", 0, 0, 1, now()))
            add_audit(con, "system", "workspace.created", "TrustPass", details="demo seed")
        for service in SERVICES:
            con.execute("INSERT OR IGNORE INTO consents(user_id,service_id,granted,updated_at) VALUES(?,?,?,?)", ("usr_student_01", service["id"], 1 if service["id"] == "library" else 0, now()))
        for user_id in ("usr_student_01", "usr_admin_01"):
            for code in ("A7KP-94QX", "M3DV-18TZ", "R6WB-52JN", "H8LC-37PF"):
                con.execute("INSERT OR IGNORE INTO backup_codes(user_id,code_hash,used) VALUES(?,?,0)", (user_id, hashlib.sha256(code.encode()).hexdigest()))


def signed_pass(user_id: str, jti: str, exp: int) -> str:
    payload = f"{user_id}.{jti}.{exp}"
    signature = hmac.new(SIGNING_KEY, payload.encode(), hashlib.sha256).hexdigest()
    return base64.urlsafe_b64encode(f"{payload}.{signature}".encode()).decode().rstrip("=")


def decode_pass(token: str):
    raw = base64.urlsafe_b64decode(token + "=" * ((4 - len(token) % 4) % 4)).decode()
    user_id, jti, exp, sig = raw.rsplit(".", 3)
    payload = f"{user_id}.{jti}.{exp}"
    expected = hmac.new(SIGNING_KEY, payload.encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(sig, expected) or int(exp) < int(time.time()):
        raise ValueError("expired or invalid pass")
    return user_id, jti, int(exp)


class Handler(BaseHTTPRequestHandler):
    server_version = "TrustPassDemo/1.0"

    def log_message(self, *_):
        return

    def send_json(self, code, data, headers=None):
        body = json.dumps(data, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "strict-origin-when-cross-origin")
        self.send_header("Content-Security-Policy", "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'")
        for k, v in (headers or {}).items(): self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def read_body(self):
        size = min(int(self.headers.get("Content-Length", "0")), 100_000)
        return json.loads(self.rfile.read(size) or b"{}")

    def cookie_token(self):
        cookie = SimpleCookie(self.headers.get("Cookie", ""))
        morsel = cookie.get("tp_session")
        return morsel.value if morsel else None

    def authenticated(self, con):
        token = self.cookie_token()
        if not token: return None
        row = con.execute("SELECT s.id AS session_id,s.user_id,u.* FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token_hash=? AND s.revoked=0 AND s.expires_at> ? AND u.active=1", (hashlib.sha256(token.encode()).hexdigest(), int(time.time()))).fetchone()
        return row

    def require_user(self, con):
        user = self.authenticated(con)
        if not user: self.send_json(401, {"error": "Sign in to continue."}); return None
        return user

    def do_GET(self):
        path = urlparse(self.path).path
        if path.startswith("/api/"):
            with connect() as con:
                if path == "/api/bootstrap":
                    return self.send_json(200, {"services": SERVICES, "attributes": ATTRIBUTES,
                        "demo": {"student_email": "aarav.sharma@northfield.edu", "student_password": "CampusDemo!26", "admin_email": "admin@northfield.edu", "admin_password": "CampusAdmin!26", "otp": {"student": totp("JBSWY3DPEHPK3PXP"), "admin": totp("KRSXG5DSNFXGOIDB")}, "otp_refresh": int(time.time()) + (30 - int(time.time()) % 30)}})
                if path == "/api/me":
                    user = self.authenticated(con)
                    if not user: return self.send_json(401, {"error": "Sign in to continue."})
                    return self.send_json(200, self.dashboard(con, user))
                user = self.require_user(con)
                if not user: return
                if path == "/api/audit":
                    where, params = ("WHERE actor=?", (user["name"],)) if user["role"] not in ("Security Admin", "Service Admin") else ("", ())
                    rows = con.execute(f"SELECT * FROM audit {where} ORDER BY id DESC LIMIT 80", params).fetchall()
                    return self.send_json(200, {"entries": [dict(x) for x in rows], "verified": self.verify_chain(con), "count": con.execute("SELECT COUNT(*) FROM audit").fetchone()[0]})
                if path == "/api/sessions":
                    rows = con.execute("SELECT id,device,created_at,last_seen,expires_at FROM sessions WHERE user_id=? AND revoked=0 AND expires_at>? ORDER BY last_seen DESC", (user["id"], int(time.time()))).fetchall()
                    return self.send_json(200, {"sessions": [dict(x) for x in rows]})
                if path == "/api/admin/overview":
                    if user["role"] not in ("Security Admin", "Service Admin"): return self.send_json(403, {"error": "Admin access is required."})
                    users = con.execute("SELECT id,email,name,role,roll_number,program,year,hostel,active FROM users ORDER BY role,name").fetchall()
                    return self.send_json(200, {"users": [dict(x) for x in users], "audit_count": con.execute("SELECT COUNT(*) FROM audit").fetchone()[0], "active_sessions": con.execute("SELECT COUNT(*) FROM sessions WHERE revoked=0 AND expires_at>?", (int(time.time()),)).fetchone()[0]})
                return self.send_json(404, {"error": "Not found."})
        static_root = ROOT / "frontend"
        file_path = static_root / (Path("index.html") if path in ("/", "") else Path(path.lstrip("/")))
        try:
            resolved = file_path.resolve()
            if static_root.resolve() not in resolved.parents: raise FileNotFoundError
            content = resolved.read_bytes()
            mime = "text/html; charset=utf-8" if resolved.suffix == ".html" else "text/css; charset=utf-8" if resolved.suffix == ".css" else "application/javascript; charset=utf-8" if resolved.suffix == ".js" else "application/octet-stream"
            self.send_response(200); self.send_header("Content-Type", mime); self.send_header("Cache-Control", "no-cache"); self.send_header("Content-Length", str(len(content))); self.end_headers(); self.wfile.write(content)
        except (OSError, ValueError): self.send_json(404, {"error": "Not found."})

    def do_POST(self):
        path = urlparse(self.path).path
        body = self.read_body()
        with connect() as con:
            if path == "/api/login":
                email = str(body.get("email", "")).strip().lower()
                failures, blocked_until = LOGIN_FAILURES.get(email, (0, 0))
                if blocked_until > int(time.time()):
                    return self.send_json(429, {"error": "Too many sign-in attempts. Wait a minute, then try again."})
                row = con.execute("SELECT * FROM users WHERE email=?", (email,)).fetchone()
                ok = row and row["active"] and password_ok(str(body.get("password", "")), row["password_hash"]) and hmac.compare_digest(str(body.get("otp", "")), totp(row["otp_secret"]))
                if not ok:
                    failures += 1
                    blocked_until = int(time.time()) + 60 if failures >= 5 else 0
                    LOGIN_FAILURES[email] = (0 if blocked_until else failures, blocked_until)
                    add_audit(con, row["name"] if row else email, "auth.failed", email)
                    return self.send_json(401, {"error": "Those details did not match. Check your password and current authenticator code."})
                LOGIN_FAILURES.pop(email, None)
                token = secrets.token_urlsafe(32); session_id = secrets.token_hex(12); ts = now(); exp = int(time.time()) + 12 * 3600
                con.execute("INSERT INTO sessions VALUES(?,?,?,?,?,?,?,0)", (session_id, row["id"], hashlib.sha256(token.encode()).hexdigest(), self.headers.get("User-Agent", "Web browser")[:140], ts, ts, exp))
                add_audit(con, row["name"], "auth.success", row["id"])
                return self.send_json(200, self.dashboard(con, row), {"Set-Cookie": f"tp_session={token}; HttpOnly; SameSite=Strict; Path=/; Max-Age=43200"})
            if path == "/api/verify":
                service_id = str(body.get("service_id", "")); service = next((s for s in SERVICES if s["id"] == service_id), None)
                try: uid, jti, exp = decode_pass(str(body.get("token", "")))
                except Exception: return self.send_json(400, {"valid": False, "error": "This pass is expired or invalid."})
                if not service: return self.send_json(400, {"valid": False, "error": "Unknown campus service."})
                user = con.execute("SELECT * FROM users WHERE id=? AND active=1", (uid,)).fetchone()
                pass_row = con.execute("SELECT * FROM passes WHERE jti_hash=? AND user_id=? AND expires_at>? AND used=0", (hashlib.sha256(jti.encode()).hexdigest(), uid, int(time.time()))).fetchone()
                if not user or not pass_row: return self.send_json(409, {"valid": False, "error": "This pass was already used or revoked."})
                consent = con.execute("SELECT granted FROM consents WHERE user_id=? AND service_id=?", (uid, service_id)).fetchone()
                if not consent or not consent[0]: return self.send_json(403, {"valid": False, "error": "The student has not approved this service."})
                con.execute("UPDATE passes SET used=1 WHERE jti_hash=?", (hashlib.sha256(jti.encode()).hexdigest(),))
                shared = {"is_enrolled": True, "full_name": user["name"], "roll_number": user["roll_number"], "program": user["program"], "hostel_resident": bool(user["hostel"])}
                data = {key: shared[key] for key in service["attributes"]}
                add_audit(con, user["name"], "identity.verified", user["id"], service["name"], ",".join(service["attributes"]))
                return self.send_json(200, {"valid": True, "service": service["name"], "attributes": data, "expires_at": exp})
            if path == "/api/recovery/start":
                email = str(body.get("email", "")).strip().lower()
                backup = str(body.get("backup_code", "")).upper()
                row = con.execute("SELECT * FROM users WHERE email=? AND active=1", (email,)).fetchone()
                backup_hash = hashlib.sha256(backup.encode()).hexdigest()
                saved = con.execute("SELECT 1 FROM backup_codes WHERE user_id=? AND code_hash=? AND used=0", (row["id"], backup_hash)).fetchone() if row else None
                if not row or not password_ok(str(body.get("password", "")), row["password_hash"]) or not saved:
                    return self.send_json(401, {"error": "The account details or backup code could not be verified."})
                con.execute("UPDATE backup_codes SET used=1 WHERE user_id=? AND code_hash=?", (row["id"], backup_hash))
                rid = secrets.token_hex(12); recovery_code = f"{secrets.randbelow(1_000_000):06d}"; exp = int(time.time()) + 900; cool = int(time.time()) + 15
                con.execute("INSERT INTO recovery VALUES(?,?,?,?,?,0)", (rid, row["id"], hashlib.sha256(recovery_code.encode()).hexdigest(), exp, cool))
                add_audit(con, row["name"], "recovery.requested", row["id"], details="cooling-off started")
                return self.send_json(200, {"recovery_id": rid, "email_code": recovery_code, "cooling_seconds": 15, "message": "For this local demo, the email code is displayed here. In a real deployment it would be sent to your verified campus inbox."})
            if path == "/api/recovery/complete":
                rid = str(body.get("recovery_id", "")); code = str(body.get("email_code", ""))
                row = con.execute("SELECT r.*,u.name FROM recovery r JOIN users u ON u.id=r.user_id WHERE r.id=? AND r.used=0", (rid,)).fetchone()
                if not row or row["expires_at"] < int(time.time()) or row["cooling_until"] > int(time.time()) or not hmac.compare_digest(row["code_hash"], hashlib.sha256(code.encode()).hexdigest()):
                    return self.send_json(400, {"error": "Recovery code is invalid or the cooling-off period is still active."})
                con.execute("UPDATE recovery SET used=1 WHERE id=?", (rid,)); con.execute("UPDATE sessions SET revoked=1 WHERE user_id=?", (row["user_id"],)); add_audit(con, row["name"], "recovery.completed", row["user_id"], details="all sessions revoked")
                return self.send_json(200, {"ok": True, "message": "Recovery complete. All signed-in devices have been signed out. Sign in again and set up your authenticator."}, {"Set-Cookie": "tp_session=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0"})
            user = self.require_user(con)
            if not user: return
            if path == "/api/logout":
                con.execute("UPDATE sessions SET revoked=1 WHERE id=?", (user["session_id"],)); add_audit(con, user["name"], "session.logout", user["session_id"])
                return self.send_json(200, {"ok": True}, {"Set-Cookie": "tp_session=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0"})
            if path == "/api/pass":
                jti = secrets.token_urlsafe(20); exp = int(time.time()) + 30
                con.execute("INSERT INTO passes(jti_hash,user_id,expires_at) VALUES(?,?,?)", (hashlib.sha256(jti.encode()).hexdigest(), user["id"], exp))
                return self.send_json(200, {"token": signed_pass(user["id"], jti, exp), "expires_at": exp})
            return self.send_json(404, {"error": "Not found."})

    def do_PUT(self):
        path = urlparse(self.path).path; body = self.read_body()
        with connect() as con:
            user = self.require_user(con)
            if not user: return
            if path.startswith("/api/consents/"):
                service_id = path.rsplit("/", 1)[-1]; service = next((s for s in SERVICES if s["id"] == service_id), None)
                if not service: return self.send_json(404, {"error": "Unknown service."})
                granted = 1 if body.get("granted") else 0
                con.execute("INSERT INTO consents VALUES(?,?,?,?) ON CONFLICT(user_id,service_id) DO UPDATE SET granted=excluded.granted,updated_at=excluded.updated_at", (user["id"], service_id, granted, now()))
                add_audit(con, user["name"], "consent.granted" if granted else "consent.revoked", service_id, service["name"], ",".join(service["attributes"]))
                return self.send_json(200, {"ok": True, "granted": bool(granted)})
            if path.startswith("/api/sessions/") and path.endswith("/revoke"):
                session_id = path.split("/")[3]
                result = con.execute("UPDATE sessions SET revoked=1 WHERE id=? AND user_id=? AND revoked=0", (session_id, user["id"]))
                if not result.rowcount: return self.send_json(404, {"error": "Session not found."})
                add_audit(con, user["name"], "session.revoked", session_id)
                return self.send_json(200, {"ok": True})
            if path.startswith("/api/admin/users/") and path.endswith("/role"):
                if user["role"] != "Security Admin": return self.send_json(403, {"error": "Security Admin access is required."})
                target = path.split("/")[4]; role = str(body.get("role", ""))
                if role not in ("Student", "Faculty", "Staff", "Service Admin", "Security Admin"): return self.send_json(400, {"error": "Unknown role."})
                result = con.execute("UPDATE users SET role=? WHERE id=?", (role, target))
                if not result.rowcount: return self.send_json(404, {"error": "User not found."})
                add_audit(con, user["name"], "role.changed", target, details=role)
                return self.send_json(200, {"ok": True})
            if path.startswith("/api/admin/users/") and path.endswith("/suspend"):
                if user["role"] != "Security Admin": return self.send_json(403, {"error": "Security Admin access is required."})
                target = path.split("/")[4]; result = con.execute("UPDATE users SET active=CASE active WHEN 1 THEN 0 ELSE 1 END WHERE id=?", (target,))
                if not result.rowcount: return self.send_json(404, {"error": "User not found."})
                con.execute("UPDATE sessions SET revoked=1 WHERE user_id=?", (target,)); add_audit(con, user["name"], "identity.status.changed", target)
                return self.send_json(200, {"ok": True})
            return self.send_json(404, {"error": "Not found."})

    def dashboard(self, con, user):
        services = []
        for svc in SERVICES:
            consent = con.execute("SELECT granted,updated_at FROM consents WHERE user_id=? AND service_id=?", (user["id"], svc["id"])).fetchone()
            services.append({**svc, "granted": bool(consent[0]) if consent else False, "consent_updated": consent[1] if consent else None})
        recent = con.execute("SELECT id,created_at,action,target,service,details FROM audit WHERE actor=? ORDER BY id DESC LIMIT 8", (user["name"],)).fetchall()
        active_sessions = con.execute("SELECT COUNT(*) FROM sessions WHERE user_id=? AND revoked=0 AND expires_at>?", (user["id"], int(time.time()))).fetchone()[0]
        return {"user": {"id": user["id"], "name": user["name"], "email": user["email"], "role": user["role"], "roll_number": user["roll_number"], "program": user["program"], "year": user["year"], "hostel_resident": bool(user["hostel"]), "active": bool(user["active"])}, "services": services, "recent_activity": [dict(x) for x in recent], "active_sessions": active_sessions, "security": {"mfa": True, "session_hours": 12, "audit_chain": self.verify_chain(con)}}

    @staticmethod
    def verify_chain(con):
        previous = "0" * 64
        for entry in con.execute("SELECT * FROM audit ORDER BY id"):
            if entry["previous_hash"] != previous: return False
            payload = "|".join((entry["created_at"], entry["actor"], entry["action"], entry["target"], entry["service"], entry["details"], previous))
            digest = hashlib.sha256(payload.encode()).hexdigest()
            if not hmac.compare_digest(digest, entry["entry_hash"]): return False
            previous = entry["entry_hash"]
        return True


if __name__ == "__main__":
    init_db()
    print(f"TrustPass API and frontend running at http://127.0.0.1:{PORT}")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
