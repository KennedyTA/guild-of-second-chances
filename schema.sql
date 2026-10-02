-- Midweek Lantern portal: database for the character builder and the live table.
-- Tables live in a private schema the public API cannot reach; the page talks only to the functions below.

create extension if not exists pgcrypto with schema extensions;
create schema if not exists wt;
revoke all on schema wt from public, anon, authenticated;

create table if not exists wt.players(
  id uuid primary key default gen_random_uuid(),
  token text unique not null default encode(extensions.gen_random_bytes(12), 'hex'),
  label text not null,
  data jsonb,
  secret text,
  created_at timestamptz not null default now(),
  updated_at timestamptz
);
create table if not exists wt.settings(key text primary key, value text not null);
create table if not exists wt.table_state(
  id int primary key default 1 check (id = 1),
  dm jsonb not null default '{}'::jsonb,
  pub jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
insert into wt.table_state(id) values (1) on conflict do nothing;

create or replace function wt.check_dm(p_pass text) returns void
language plpgsql security definer set search_path = '' as $$
declare h text;
begin
  select value into h from wt.settings where key = 'dm_pass_hash';
  if h is null or p_pass is null or extensions.crypt(p_pass, h) <> h then
    raise exception 'Wrong passphrase' using errcode = '28P01';
  end if;
end $$;
revoke all on function wt.check_dm(text) from public, anon, authenticated;

-- players
create or replace function public.wt_get_my_character(p_token text) returns json
language sql security definer set search_path = '' stable as $$
  select json_build_object('label', label, 'data', data) from wt.players where token = p_token;
$$;

create or replace function public.wt_save_my_character(p_token text, p_data jsonb, p_secret text) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  if octet_length(p_data::text) > 60000 or octet_length(coalesce(p_secret, '')) > 4000 then
    raise exception 'Too much text';
  end if;
  update wt.players set data = p_data, secret = nullif(p_secret, ''), updated_at = now() where token = p_token;
  if not found then raise exception 'Unknown link'; end if;
  return true;
end $$;

-- DM
create or replace function public.wt_dm_list(p_pass text) returns json
language plpgsql security definer set search_path = '' as $$
begin
  perform wt.check_dm(p_pass);
  return coalesce((select json_agg(json_build_object('id', id, 'label', label, 'token', token, 'data', data, 'secret', secret, 'updated_at', updated_at) order by created_at) from wt.players), '[]'::json);
end $$;

create or replace function public.wt_dm_add_player(p_pass text, p_label text) returns text
language plpgsql security definer set search_path = '' as $$
declare t text;
begin
  perform wt.check_dm(p_pass);
  insert into wt.players(label) values (left(trim(p_label), 60)) returning token into t;
  return t;
end $$;

create or replace function public.wt_dm_remove_player(p_pass text, p_id uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  perform wt.check_dm(p_pass);
  delete from wt.players where id = p_id;
  return true;
end $$;

create or replace function public.wt_dm_save_character(p_pass text, p_id uuid, p_data jsonb) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  perform wt.check_dm(p_pass);
  update wt.players set data = p_data, updated_at = now() where id = p_id;
  return true;
end $$;

-- live table: players read only the public half
create or replace function public.wt_table_get() returns json
language sql security definer set search_path = '' stable as $$
  select json_build_object('pub', pub, 'at', updated_at) from wt.table_state where id = 1;
$$;

create or replace function public.wt_dm_table_get(p_pass text) returns json
language plpgsql security definer set search_path = '' as $$
begin
  perform wt.check_dm(p_pass);
  return (select json_build_object('dm', dm, 'pub', pub, 'at', updated_at) from wt.table_state where id = 1);
end $$;

create or replace function public.wt_dm_table_set(p_pass text, p_dm jsonb, p_pub jsonb) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  perform wt.check_dm(p_pass);
  if octet_length(p_dm::text) > 200000 then raise exception 'Too much text'; end if;
  update wt.table_state set dm = p_dm, pub = p_pub, updated_at = now() where id = 1;
  return true;
end $$;

revoke all on function public.wt_get_my_character(text), public.wt_save_my_character(text, jsonb, text),
  public.wt_dm_list(text), public.wt_dm_add_player(text, text), public.wt_dm_remove_player(text, uuid),
  public.wt_dm_save_character(text, uuid, jsonb), public.wt_table_get(), public.wt_dm_table_get(text),
  public.wt_dm_table_set(text, jsonb, jsonb) from public;
grant execute on function public.wt_get_my_character(text), public.wt_save_my_character(text, jsonb, text),
  public.wt_dm_list(text), public.wt_dm_add_player(text, text), public.wt_dm_remove_player(text, uuid),
  public.wt_dm_save_character(text, uuid, jsonb), public.wt_table_get(), public.wt_dm_table_get(text),
  public.wt_dm_table_set(text, jsonb, jsonb) to anon;

-- Tom sets the DM passphrase himself in the SQL editor (replace the words in quotes):
-- insert into wt.settings values ('dm_pass_hash', extensions.crypt('your passphrase here', extensions.gen_salt('bf')))
--   on conflict (key) do update set value = excluded.value;

-- art: monster images (shown at once) and character portraits (hidden until the DM reveals them)
create table if not exists wt.art(
  id text primary key,
  data text not null,
  shown boolean not null default false,
  updated_at timestamptz not null default now()
);

create or replace function public.wt_get_my_character(p_token text) returns json
language sql security definer set search_path = '' stable as $$
  select json_build_object('id', id, 'label', label, 'data', data) from wt.players where token = p_token;
$$;

create or replace function public.wt_dm_art_put(p_pass text, p_id text, p_data text, p_shown boolean) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  perform wt.check_dm(p_pass);
  if octet_length(p_data) > 900000 or p_data not like 'data:image/%' then raise exception 'Image too large or not an image'; end if;
  insert into wt.art(id, data, shown) values (p_id, p_data, p_shown)
    on conflict (id) do update set data = excluded.data, updated_at = now();
  return true;
end $$;

create or replace function public.wt_dm_art_show(p_pass text, p_id text, p_shown boolean) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  perform wt.check_dm(p_pass);
  update wt.art set shown = p_shown, updated_at = now() where id = p_id;
  return true;
end $$;

create or replace function public.wt_dm_art_del(p_pass text, p_id text) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  perform wt.check_dm(p_pass);
  delete from wt.art where id = p_id;
  return true;
end $$;

create or replace function public.wt_dm_art_list(p_pass text) returns json
language plpgsql security definer set search_path = '' as $$
begin
  perform wt.check_dm(p_pass);
  return coalesce((select json_agg(json_build_object('id', id, 'shown', shown, 'v', extract(epoch from updated_at)::text)) from wt.art), '[]'::json);
end $$;

create or replace function public.wt_art_index(p_ids text[]) returns json
language sql security definer set search_path = '' stable as $$
  select coalesce(json_agg(json_build_object('id', id, 'v', extract(epoch from updated_at)::text)), '[]'::json)
  from wt.art where shown and id = any(p_ids[1:40]);
$$;

create or replace function public.wt_art_get(p_ids text[], p_pass text default null) returns json
language plpgsql security definer set search_path = '' as $$
begin
  if p_pass is not null then perform wt.check_dm(p_pass); end if;
  return coalesce((select json_agg(json_build_object('id', id, 'data', data, 'v', extract(epoch from updated_at)::text))
    from wt.art where id = any(p_ids[1:20]) and (shown or p_pass is not null)), '[]'::json);
end $$;

revoke all on function public.wt_dm_art_put(text, text, text, boolean), public.wt_dm_art_show(text, text, boolean),
  public.wt_dm_art_del(text, text), public.wt_dm_art_list(text), public.wt_art_index(text[]), public.wt_art_get(text[], text) from public;
grant execute on function public.wt_dm_art_put(text, text, text, boolean), public.wt_dm_art_show(text, text, boolean),
  public.wt_dm_art_del(text, text), public.wt_dm_art_list(text), public.wt_art_index(text[]), public.wt_art_get(text[], text) to anon;

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
