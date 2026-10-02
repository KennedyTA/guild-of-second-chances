-- Guild portal update 2: live HP, conditions, spell slots and powers for each character.
-- Safe to run more than once.

alter table wt.players add column if not exists live jsonb not null default '{}'::jsonb;

create or replace function public.wt_get_my_character(p_token text) returns json
language sql security definer set search_path = '' stable as $$
  select json_build_object('id', id, 'label', label, 'data', data, 'live', live) from wt.players where token = p_token;
$$;

create or replace function public.wt_save_my_live(p_token text, p_live jsonb) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  if octet_length(p_live::text) > 8000 then raise exception 'Too much text'; end if;
  update wt.players set live = p_live where token = p_token and data is not null;
  if not found then raise exception 'Unknown link'; end if;
  return true;
end $$;

create or replace function public.wt_dm_save_live(p_pass text, p_id uuid, p_live jsonb) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  perform wt.check_dm(p_pass);
  if octet_length(p_live::text) > 8000 then raise exception 'Too much text'; end if;
  update wt.players set live = p_live where id = p_id;
  return true;
end $$;

-- the table sees the party's game numbers only: no story answers, no secrets, no links
create or replace function public.wt_party_get() returns json
language sql security definer set search_path = '' stable as $$
  select coalesce(json_agg(json_build_object('id', id,
      'data', data - array['look','personality','drive','tie','never','likes','avail','away'],
      'live', live) order by created_at), '[]'::json)
  from wt.players where data is not null;
$$;

create or replace function public.wt_dm_list(p_pass text) returns json
language plpgsql security definer set search_path = '' as $$
begin
  perform wt.check_dm(p_pass);
  return coalesce((select json_agg(json_build_object('id', id, 'label', label, 'token', token, 'data', data, 'secret', secret, 'live', live, 'updated_at', updated_at) order by created_at) from wt.players), '[]'::json);
end $$;

revoke all on function public.wt_save_my_live(text, jsonb), public.wt_dm_save_live(text, uuid, jsonb), public.wt_party_get() from public;
grant execute on function public.wt_save_my_live(text, jsonb), public.wt_dm_save_live(text, uuid, jsonb), public.wt_party_get() to anon;
