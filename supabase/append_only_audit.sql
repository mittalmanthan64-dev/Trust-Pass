-- Apply this in the Supabase SQL Editor to protect an existing TrustPass database.
create or replace function private.prevent_audit_mutation()
returns trigger language plpgsql set search_path = '' as $$
begin
  raise exception 'audit records are append-only';
end;
$$;

revoke all on function private.prevent_audit_mutation() from public, anon, authenticated;
drop trigger if exists audit_append_only on private.audit;
create trigger audit_append_only before update or delete on private.audit
for each row execute function private.prevent_audit_mutation();
