-- Guild portal update 4: solo missions a player can play remotely on their own link, and the perks they earn.
-- Paste the whole file into the Supabase SQL editor and run it. Safe to run more than once.

create table if not exists wt.missions(
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references wt.players(id) on delete cascade,
  def jsonb not null,
  state jsonb not null default '{}'::jsonb,
  sent boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists missions_player on wt.missions(player_id);

-- a player sees only their own missions, and only once the DM has sent them
create or replace function public.wt_my_missions(p_token text) returns json
language sql security definer set search_path = '' stable as $$
  select coalesce(json_agg(json_build_object('id', m.id, 'def', m.def, 'state', m.state) order by m.created_at), '[]'::json)
  from wt.missions m join wt.players p on p.id = m.player_id
  where p.token = p_token and m.sent;
$$;

-- a player saves their own progress. A finished mission is closed: after that only the "perk used" mark can change.
create or replace function public.wt_mission_save(p_token text, p_id uuid, p_state jsonb) returns boolean
language plpgsql security definer set search_path = '' as $$
declare cur jsonb;
begin
  if p_state is null or jsonb_typeof(p_state) <> 'object' or octet_length(p_state::text) > 30000 then
    raise exception 'Too much text';
  end if;
  select m.state into cur from wt.missions m join wt.players p on p.id = m.player_id
    where m.id = p_id and p.token = p_token and m.sent for update of m;
  if not found then raise exception 'Unknown mission'; end if;
  if cur ? 'done' then
    update wt.missions set state = cur || jsonb_build_object('used', coalesce((p_state->>'used')::boolean, false)), updated_at = now() where id = p_id;
  else
    update wt.missions set state = p_state, updated_at = now() where id = p_id;
  end if;
  return true;
end $$;

-- DM
create or replace function public.wt_dm_missions(p_pass text) returns json
language plpgsql security definer set search_path = '' as $$
begin
  perform wt.check_dm(p_pass);
  return coalesce((select json_agg(json_build_object('id', id, 'player', player_id, 'def', def, 'state', state, 'sent', sent,
    'updated_at', updated_at) order by created_at) from wt.missions), '[]'::json);
end $$;

create or replace function public.wt_dm_mission_put(p_pass text, p_id uuid, p_player uuid, p_def jsonb) returns uuid
language plpgsql security definer set search_path = '' as $$
declare r uuid;
begin
  perform wt.check_dm(p_pass);
  if p_def is null or jsonb_typeof(p_def) <> 'object' or octet_length(p_def::text) > 60000 then raise exception 'Too much text'; end if;
  if p_id is null then
    insert into wt.missions(player_id, def) values (p_player, p_def) returning id into r;
  else
    update wt.missions set def = p_def, updated_at = now() where id = p_id returning id into r;
    if r is null then raise exception 'Unknown mission'; end if;
  end if;
  return r;
end $$;

create or replace function public.wt_dm_mission_send(p_pass text, p_id uuid, p_sent boolean) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  perform wt.check_dm(p_pass);
  update wt.missions set sent = p_sent, updated_at = now() where id = p_id;
  return true;
end $$;

-- the DM can set the state outright: reset a mission with '{}', move a waiting player on, or mark a perk used
create or replace function public.wt_dm_mission_state(p_pass text, p_id uuid, p_state jsonb) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  perform wt.check_dm(p_pass);
  if p_state is null or jsonb_typeof(p_state) <> 'object' or octet_length(p_state::text) > 30000 then raise exception 'Too much text'; end if;
  update wt.missions set state = p_state, updated_at = now() where id = p_id;
  return true;
end $$;

create or replace function public.wt_dm_mission_del(p_pass text, p_id uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  perform wt.check_dm(p_pass);
  delete from wt.missions where id = p_id;
  return true;
end $$;

revoke all on function public.wt_my_missions(text), public.wt_mission_save(text, uuid, jsonb), public.wt_dm_missions(text),
  public.wt_dm_mission_put(text, uuid, uuid, jsonb), public.wt_dm_mission_send(text, uuid, boolean),
  public.wt_dm_mission_state(text, uuid, jsonb), public.wt_dm_mission_del(text, uuid) from public;
grant execute on function public.wt_my_missions(text), public.wt_mission_save(text, uuid, jsonb), public.wt_dm_missions(text),
  public.wt_dm_mission_put(text, uuid, uuid, jsonb), public.wt_dm_mission_send(text, uuid, boolean),
  public.wt_dm_mission_state(text, uuid, jsonb), public.wt_dm_mission_del(text, uuid) to anon;

-- tell the API about the new functions straight away
notify pgrst, 'reload schema';
