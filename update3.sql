-- Guild portal update 3: DM-dealt cards and gifts per player, and private whispers.
-- Safe to run more than once.

alter table wt.players add column if not exists preset jsonb not null default '{}'::jsonb;
alter table wt.players add column if not exists inbox jsonb not null default '[]'::jsonb;

create or replace function public.wt_get_my_character(p_token text) returns json
language sql security definer set search_path = '' stable as $$
  select json_build_object('id', id, 'label', label, 'data', data, 'live', live, 'preset', preset) from wt.players where token = p_token;
$$;

create or replace function public.wt_dm_list(p_pass text) returns json
language plpgsql security definer set search_path = '' as $$
begin
  perform wt.check_dm(p_pass);
  return coalesce((select json_agg(json_build_object('id', id, 'label', label, 'token', token, 'data', data, 'secret', secret,
    'live', live, 'preset', preset, 'inbox', inbox, 'updated_at', updated_at) order by created_at) from wt.players), '[]'::json);
end $$;

create or replace function public.wt_dm_set_preset(p_pass text, p_id uuid, p_preset jsonb) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  perform wt.check_dm(p_pass);
  if octet_length(p_preset::text) > 4000 then raise exception 'Too much text'; end if;
  update wt.players set preset = p_preset where id = p_id;
  return true;
end $$;

-- whispers: the DM writes to one player; only that player's link can read it
create or replace function public.wt_dm_whisper(p_pass text, p_id uuid, p_text text) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  perform wt.check_dm(p_pass);
  if p_text is null or length(trim(p_text)) = 0 or octet_length(p_text) > 2000 then raise exception 'Empty or too long'; end if;
  update wt.players set inbox = (
    select coalesce(jsonb_agg(x.e order by x.n), '[]'::jsonb) from (
      select e, n from jsonb_array_elements(inbox || jsonb_build_array(jsonb_build_object('id', gen_random_uuid()::text, 'text', p_text, 'at', now())))
        with ordinality as t(e, n)
      order by n desc limit 20) x)
  where id = p_id;
  return true;
end $$;

create or replace function public.wt_my_inbox(p_token text) returns json
language sql security definer set search_path = '' stable as $$
  select inbox::json from wt.players where token = p_token;
$$;

create or replace function public.wt_inbox_reply(p_token text, p_mid text, p_reply text) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  if octet_length(coalesce(p_reply, '')) > 2000 then raise exception 'Too long'; end if;
  update wt.players set inbox = (
    select coalesce(jsonb_agg(case when e->>'id' = p_mid then e || jsonb_build_object('reply', p_reply, 'rat', now()) else e end order by n), '[]'::jsonb)
    from jsonb_array_elements(inbox) with ordinality as t(e, n))
  where token = p_token;
  if not found then raise exception 'Unknown link'; end if;
  return true;
end $$;

revoke all on function public.wt_dm_set_preset(text, uuid, jsonb), public.wt_dm_whisper(text, uuid, text),
  public.wt_my_inbox(text), public.wt_inbox_reply(text, text, text) from public;
grant execute on function public.wt_dm_set_preset(text, uuid, jsonb), public.wt_dm_whisper(text, uuid, text),
  public.wt_my_inbox(text), public.wt_inbox_reply(text, text, text) to anon;
