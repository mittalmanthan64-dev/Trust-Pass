-- TrustPass / CampusGate initial Supabase schema
-- Apply with Supabase migrations. Auth users are managed by Supabase Auth.

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists public.campus_services (
  id text primary key,
  name text not null,
  description text not null default '',
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.service_claims (
  id text primary key,
  service_id text not null references public.campus_services(id) on delete restrict,
  description text not null default '',
  active boolean not null default true,
  unique (service_id, id)
);

create table if not exists public.campus_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  identity_id uuid not null unique default gen_random_uuid(),
  email text not null,
  display_name text not null default '',
  enrollment_status text not null default 'pending' check (enrollment_status in ('pending','active','suspended','graduated')),
  program text,
  class_year smallint check (class_year is null or class_year between 1900 and 2200),
  hostel_resident boolean,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.role_assignments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.campus_profiles(user_id) on delete cascade,
  role text not null check (role in ('student','faculty','staff','service_admin','security_admin')),
  assigned_by uuid references auth.users(id) on delete set null,
  valid_from timestamptz not null default now(),
  valid_until timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  check (valid_until is null or valid_until > valid_from)
);
create index if not exists role_assignments_user_active_idx on public.role_assignments(user_id, role) where revoked_at is null;

create table if not exists public.role_service_permissions (
  role text not null check (role in ('student','faculty','staff','service_admin','security_admin')),
  service_id text not null references public.campus_services(id) on delete cascade,
  claim_id text not null,
  primary key (role, service_id, claim_id),
  foreign key (service_id, claim_id) references public.service_claims(service_id, id) on delete cascade
);

create table if not exists public.service_consents (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.campus_profiles(user_id) on delete cascade,
  service_id text not null references public.campus_services(id) on delete restrict,
  status text not null default 'granted' check (status in ('granted','revoked')),
  granted_at timestamptz not null default now(),
  revoked_at timestamptz,
  unique (user_id, service_id),
  check ((status = 'granted' and revoked_at is null) or (status = 'revoked' and revoked_at is not null))
);

create table if not exists public.service_consent_claims (
  consent_id uuid not null references public.service_consents(id) on delete cascade,
  claim_id text not null references public.service_claims(id) on delete restrict,
  granted_at timestamptz not null default now(),
  revoked_at timestamptz,
  primary key (consent_id, claim_id)
);

-- Stable pseudonymous identifier for each identity/service pair; never reuse across services.
create table if not exists public.service_subjects (
  user_id uuid not null references public.campus_profiles(user_id) on delete cascade,
  service_id text not null references public.campus_services(id) on delete restrict,
  subject_id uuid not null default gen_random_uuid(),
  created_at timestamptz not null default now(),
  primary key (user_id, service_id),
  unique (service_id, subject_id)
);

-- Store hashes only, never access/refresh tokens in plaintext.
create table if not exists public.campus_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.campus_profiles(user_id) on delete cascade,
  service_id text references public.campus_services(id) on delete set null,
  token_hash text not null unique,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  revoked_at timestamptz,
  device_label text,
  check (expires_at > created_at)
);
create index if not exists campus_sessions_user_active_idx on public.campus_sessions(user_id, expires_at) where revoked_at is null;
create index if not exists campus_sessions_service_id_idx on public.campus_sessions(service_id);

create table if not exists public.recovery_backup_codes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.campus_profiles(user_id) on delete cascade,
  code_hash text not null,
  created_at timestamptz not null default now(),
  used_at timestamptz,
  unique (user_id, code_hash)
);

create table if not exists public.recovery_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.campus_profiles(user_id) on delete cascade,
  requested_at timestamptz not null default now(),
  available_at timestamptz not null,
  completed_at timestamptz,
  reviewed_by uuid references auth.users(id) on delete set null,
  reason text
);
create index if not exists recovery_requests_user_id_idx on public.recovery_requests(user_id);
create index if not exists recovery_requests_reviewed_by_idx on public.recovery_requests(reviewed_by);

create table if not exists public.oidc_clients (
  id text primary key,
  service_id text not null unique references public.campus_services(id) on delete restrict,
  redirect_uris text[] not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  check (cardinality(redirect_uris) > 0)
);

create table if not exists public.oidc_authorization_codes (
  code_hash text primary key,
  user_id uuid not null references public.campus_profiles(user_id) on delete cascade,
  client_id text not null references public.oidc_clients(id) on delete cascade,
  redirect_uri text not null,
  state_hash text,
  nonce_hash text,
  code_challenge text not null,
  code_challenge_method text not null default 'S256' check (code_challenge_method = 'S256'),
  scope text[] not null default '{}',
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  check (expires_at > created_at)
);
create index if not exists oidc_authorization_codes_user_id_idx on public.oidc_authorization_codes(user_id);
create index if not exists oidc_authorization_codes_client_id_idx on public.oidc_authorization_codes(client_id);

create table if not exists public.audit_events (
  id bigint generated always as identity primary key,
  occurred_at timestamptz not null default clock_timestamp(),
  -- Keep the actor UUID even if an Auth account is later removed; logs remain immutable.
  actor_user_id uuid,
  action text not null,
  target_type text not null,
  target_id text,
  service_id text,
  details jsonb not null default '{}'::jsonb,
  previous_hash text,
  event_hash text not null
);

create table if not exists public.login_rate_limits (
  identifier_hash text primary key,
  failures integer not null default 0 check (failures >= 0),
  window_started_at timestamptz not null default now(),
  locked_until timestamptz,
  updated_at timestamptz not null default now()
);

create index if not exists role_assignments_assigned_by_idx on public.role_assignments(assigned_by);
create index if not exists role_service_permissions_service_id_idx on public.role_service_permissions(service_id);
create index if not exists role_service_permissions_service_claim_idx on public.role_service_permissions(service_id, claim_id);
create index if not exists service_consent_claims_claim_id_idx on public.service_consent_claims(claim_id);
create index if not exists service_consents_service_id_idx on public.service_consents(service_id);

create or replace function private.touch_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end;
$$;

create or replace function private.create_campus_profile()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.campus_profiles(user_id, email, display_name)
  values (new.id, coalesce(new.email, ''), coalesce(new.raw_user_meta_data->>'full_name', ''))
  on conflict (user_id) do update set email = excluded.email;
  return new;
end;
$$;
revoke all on function private.create_campus_profile() from public, anon, authenticated;
drop trigger if exists on_auth_user_created_campus_profile on auth.users;
create trigger on_auth_user_created_campus_profile after insert on auth.users
for each row execute function private.create_campus_profile();

drop trigger if exists campus_profiles_touch_updated_at on public.campus_profiles;
create trigger campus_profiles_touch_updated_at before update on public.campus_profiles
for each row execute function private.touch_updated_at();

create or replace function private.audit_chain_before_insert()
returns trigger language plpgsql security definer set search_path = '' as $$
declare prior_hash text;
begin
  perform pg_advisory_xact_lock(741852963);
  select event_hash into prior_hash from public.audit_events order by id desc limit 1;
  new.previous_hash := prior_hash;
  new.occurred_at := coalesce(new.occurred_at, clock_timestamp());
  new.event_hash := encode(extensions.digest(convert_to(
    concat_ws('|', coalesce(prior_hash, ''), new.occurred_at::text, coalesce(new.actor_user_id::text, ''),
      new.action, new.target_type, coalesce(new.target_id, ''), coalesce(new.service_id, ''), new.details::text), 'UTF8'), 'sha256'), 'hex');
  return new;
end;
$$;
revoke all on function private.audit_chain_before_insert() from public, anon, authenticated;
drop trigger if exists audit_events_chain on public.audit_events;
create trigger audit_events_chain before insert on public.audit_events
for each row execute function private.audit_chain_before_insert();

create or replace function private.prevent_audit_mutation()
returns trigger language plpgsql set search_path = '' as $$
begin raise exception 'audit_events is append-only'; end;
$$;
drop trigger if exists audit_events_append_only on public.audit_events;
create trigger audit_events_append_only before update or delete on public.audit_events
for each row execute function private.prevent_audit_mutation();

create or replace function private.audit_consent_change()
returns trigger language plpgsql security definer set search_path = '' as $$
declare rec public.service_consents;
begin
  if tg_op = 'DELETE' then rec := old; else rec := new; end if;
  insert into public.audit_events(actor_user_id, action, target_type, target_id, service_id, details)
  values (auth.uid(), 'consent_' || lower(tg_op), 'service_consent', rec.id::text, rec.service_id,
    jsonb_build_object('user_id', rec.user_id, 'status', rec.status));
  if tg_op = 'DELETE' then return old; else return new; end if;
end;
$$;
revoke all on function private.audit_consent_change() from public, anon, authenticated;
drop trigger if exists service_consents_audit on public.service_consents;
create trigger service_consents_audit after insert or update or delete on public.service_consents
for each row execute function private.audit_consent_change();

create or replace function private.set_consent_timestamps()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.status = 'granted' then
    if tg_op = 'INSERT' or old.status is distinct from 'granted' then new.granted_at := now(); end if;
    new.revoked_at := null;
  else
    new.revoked_at := coalesce(new.revoked_at, now());
  end if;
  return new;
end;
$$;
drop trigger if exists service_consents_timestamps on public.service_consents;
create trigger service_consents_timestamps before insert or update on public.service_consents
for each row execute function private.set_consent_timestamps();

create or replace function private.set_recovery_cooldown()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.requested_at := now();
  new.available_at := now() + interval '24 hours';
  new.completed_at := null;
  new.reviewed_by := null;
  return new;
end;
$$;
drop trigger if exists recovery_requests_cooldown on public.recovery_requests;
create trigger recovery_requests_cooldown before insert on public.recovery_requests
for each row execute function private.set_recovery_cooldown();

create or replace function private.audit_role_change()
returns trigger language plpgsql security definer set search_path = '' as $$
declare rec public.role_assignments;
begin
  if tg_op = 'DELETE' then rec := old; else rec := new; end if;
  insert into public.audit_events(actor_user_id, action, target_type, target_id, details)
  values (auth.uid(), 'role_' || lower(tg_op), 'role_assignment', rec.id::text,
    jsonb_build_object('user_id', rec.user_id, 'role', rec.role));
  if tg_op = 'DELETE' then return old; else return new; end if;
end;
$$;
revoke all on function private.audit_role_change() from public, anon, authenticated;
drop trigger if exists role_assignments_audit on public.role_assignments;
create trigger role_assignments_audit after insert or update or delete on public.role_assignments
for each row execute function private.audit_role_change();

create or replace function private.has_active_role(requested_role text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.role_assignments r where r.user_id = (select auth.uid())
    and r.role = requested_role and r.revoked_at is null and r.valid_from <= now()
    and (r.valid_until is null or r.valid_until > now()))
$$;
revoke all on function private.has_active_role(text) from public, anon;
grant execute on function private.has_active_role(text) to authenticated;

-- Seed the four demonstration services and least-privilege boolean claims.
insert into public.campus_services(id,name,description) values
 ('library','Library','Library eligibility'), ('fees','Fee Portal','Pseudonymous fee account'),
 ('attendance','Attendance','Role and class membership'), ('lms','Learning Management System','Course access'),
 ('hostel','Hostel Services','Hostel eligibility'), ('exam_hall','Exam Hall','Exam eligibility')
on conflict (id) do update set name=excluded.name, description=excluded.description;
insert into public.service_claims(id,service_id,description) values
 ('active_student','library','Whether campus enrollment is active'),
 ('fee_subject','fees','Service-specific pseudonymous subject'),
 ('role','attendance','Campus role'), ('class_membership','attendance','Class membership boolean'),
 ('course_membership','lms','Course membership boolean'),
 ('hostel_resident','hostel','Hostel resident boolean'),
 ('exam_eligible','exam_hall','Exam eligibility boolean')
on conflict (id) do update set description=excluded.description;
insert into public.role_service_permissions(role,service_id,claim_id) values
 ('student','library','active_student'), ('student','fees','fee_subject'),
 ('student','attendance','role'), ('student','attendance','class_membership'),
 ('faculty','attendance','role'), ('student','lms','course_membership'),
 ('faculty','lms','course_membership'), ('student','hostel','hostel_resident'),
 ('student','exam_hall','exam_eligible')
on conflict do nothing;

-- Row level security is enabled everywhere in the exposed public schema.
alter table public.campus_services enable row level security;
alter table public.service_claims enable row level security;
alter table public.campus_profiles enable row level security;
alter table public.role_assignments enable row level security;
alter table public.role_service_permissions enable row level security;
alter table public.service_consents enable row level security;
alter table public.service_consent_claims enable row level security;
alter table public.service_subjects enable row level security;
alter table public.campus_sessions enable row level security;
alter table public.recovery_backup_codes enable row level security;
alter table public.recovery_requests enable row level security;
alter table public.oidc_clients enable row level security;
alter table public.oidc_authorization_codes enable row level security;
alter table public.audit_events enable row level security;
alter table public.login_rate_limits enable row level security;

create policy "active services readable by signed-in users" on public.campus_services for select to authenticated using (active);
create policy "active claims readable by signed-in users" on public.service_claims for select to authenticated using (active);
create policy "users read own profile" on public.campus_profiles for select to authenticated using (user_id = (select auth.uid()));
create policy "users update own profile" on public.campus_profiles for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "users read own roles" on public.role_assignments for select to authenticated using (user_id = (select auth.uid()));
create policy "users read permission map" on public.role_service_permissions for select to authenticated using (true);
create policy "users manage own consent" on public.service_consents for all to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "users manage own consent claims" on public.service_consent_claims for all to authenticated using (exists(select 1 from public.service_consents c join public.service_claims sc on sc.service_id = c.service_id where c.id = consent_id and c.user_id = (select auth.uid()) and sc.id = claim_id)) with check (exists(select 1 from public.service_consents c join public.service_claims sc on sc.service_id = c.service_id where c.id = consent_id and c.user_id = (select auth.uid()) and sc.id = claim_id));
create policy "users read own service subjects" on public.service_subjects for select to authenticated using (user_id = (select auth.uid()));
create policy "users read own sessions" on public.campus_sessions for select to authenticated using (user_id = (select auth.uid()));
create policy "users revoke own sessions" on public.campus_sessions for update to authenticated using (user_id = (select auth.uid()) and revoked_at is null) with check (user_id = (select auth.uid()) and revoked_at is not null);
create policy "users read own recovery codes" on public.recovery_backup_codes for select to authenticated using (user_id = (select auth.uid()));
create policy "users read own recovery requests" on public.recovery_requests for select to authenticated using (user_id = (select auth.uid()));
create policy "users request own recovery" on public.recovery_requests for insert to authenticated with check (user_id = (select auth.uid()));
create policy "active oidc clients readable" on public.oidc_clients for select to authenticated using (active);
create policy "users read own audit events" on public.audit_events for select to authenticated using (actor_user_id = (select auth.uid()));
create policy "no client access to authorization codes" on public.oidc_authorization_codes for all to authenticated using (false) with check (false);
create policy "no client access to rate limits" on public.login_rate_limits for all to authenticated using (false) with check (false);

grant select on public.campus_services, public.service_claims, public.role_assignments,
  public.role_service_permissions, public.service_consent_claims, public.service_subjects,
  public.campus_sessions, public.recovery_backup_codes, public.recovery_requests,
  public.oidc_clients, public.audit_events to authenticated;
grant select on public.campus_profiles to authenticated;
grant update (display_name) on public.campus_profiles to authenticated;
grant select, insert, update, delete on public.service_consents to authenticated;
grant select, insert, update, delete on public.service_consent_claims to authenticated;
grant update (revoked_at) on public.campus_sessions to authenticated;
grant select on public.recovery_requests to authenticated;
grant insert (user_id, reason) on public.recovery_requests to authenticated;
revoke all on public.login_rate_limits, public.oidc_authorization_codes from anon, authenticated;
revoke insert, update, delete on public.audit_events from anon, authenticated;

