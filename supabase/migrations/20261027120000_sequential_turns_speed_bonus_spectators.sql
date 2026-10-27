-- Detective Math Online: teacher-controlled start, sequential character turns,
-- speed bonus, spectator entry, and retirement of insecure legacy RPC overloads.
alter table public.mystery_rooms add column if not exists question_started_at timestamptz;
alter table public.mystery_answers
  add column if not exists elapsed_ms integer not null default 0,
  add column if not exists speed_bonus integer not null default 0;

create table if not exists public.mystery_spectators (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.mystery_rooms(id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 24),
  joined_at timestamptz not null default now(),
  unique(room_id, display_name)
);
alter table public.mystery_spectators enable row level security;
drop policy if exists "spectators read roster" on public.mystery_spectators;
create policy "spectators read roster" on public.mystery_spectators for select to anon, authenticated using (true);
revoke insert, update, delete on public.mystery_spectators from anon, authenticated;

create or replace function public.join_mystery_room(p_room_code text,p_display_name text,p_character_id text)
returns public.mystery_players language plpgsql security definer set search_path = public as $$
declare r public.mystery_rooms; p public.mystery_players;
begin
  select * into r from public.mystery_rooms
  where upper(coalesce(room_code,code))=upper(trim(p_room_code)) or upper(code)=upper(trim(p_room_code))
  order by created_at desc limit 1 for update;
  if not found then raise exception 'Room not found. Check the room code.'; end if;
  if r.status <> 'waiting' then raise exception 'This mission has already started. Join as a spectator instead.'; end if;
  if (select count(*) from public.mystery_players where room_id=r.id) >= 4 then raise exception 'This room is full. Join as a spectator instead.'; end if;
  if p_character_id not in ('conan','ai','mitsuhiko','genta') then raise exception 'Choose a valid character.'; end if;
  if exists(select 1 from public.mystery_players where room_id=r.id and character_id=p_character_id) then raise exception 'This character has already been selected. Please choose another character.'; end if;
  if char_length(trim(p_display_name)) not between 1 and 24 then raise exception 'Name must be 1–24 characters.'; end if;
  insert into public.mystery_players(room_id,display_name,character_id) values(r.id,trim(p_display_name),p_character_id) returning * into p;
  return p;
end $$;

create or replace function public.join_mystery_spectator(p_room_code text,p_display_name text)
returns public.mystery_spectators language plpgsql security definer set search_path = public as $$
declare r public.mystery_rooms; s public.mystery_spectators;
begin
  select * into r from public.mystery_rooms
  where upper(coalesce(room_code,code))=upper(trim(p_room_code)) or upper(code)=upper(trim(p_room_code))
  order by created_at desc limit 1 for update;
  if not found then raise exception 'Room not found. Check the room code.'; end if;
  if r.status <> 'playing' then raise exception 'Spectator entry is available after the mission starts.'; end if;
  if char_length(trim(p_display_name)) not between 1 and 24 then raise exception 'Name must be 1–24 characters.'; end if;
  insert into public.mystery_spectators(room_id,display_name) values(r.id,trim(p_display_name))
  on conflict (room_id,display_name) do update set display_name=excluded.display_name returning * into s;
  return s;
end $$;

create or replace function public.start_mystery_room(p_room_code text)
returns public.mystery_rooms language plpgsql security definer set search_path = public as $$
declare r public.mystery_rooms;
begin
  if auth.uid() is null or coalesce(auth.jwt()->'app_metadata'->>'role','') <> 'teacher' then raise exception 'Only an authenticated teacher can start a room'; end if;
  select * into r from public.mystery_rooms
  where upper(coalesce(room_code,code))=upper(trim(p_room_code)) or upper(code)=upper(trim(p_room_code))
  order by created_at desc limit 1 for update;
  if not found then raise exception 'Room not found.'; end if;
  if r.status <> 'waiting' then raise exception 'This room is not waiting to start.'; end if;
  if (select count(*) from public.mystery_players where room_id=r.id) <> 4 then raise exception 'All four detectives must join before the teacher starts the mission.'; end if;
  update public.mystery_rooms set status='playing',question_index=0,question_started_at=now(),updated_at=now() where id=r.id returning * into r;
  return r;
end $$;

create or replace function public.submit_mystery_answer(p_player_id uuid,p_question_index integer,p_answer integer)
returns jsonb language plpgsql security definer set search_path = public as $$
declare p public.mystery_players; r public.mystery_rooms; q jsonb; correct boolean;
  active_player_id uuid; elapsed integer; bonus integer := 0; next_index integer; new_score integer;
begin
  select * into p from public.mystery_players where id=p_player_id for update;
  if not found then raise exception 'Player not found.'; end if;
  select * into r from public.mystery_rooms where id=p.room_id for update;
  if r.status <> 'playing' then raise exception 'The mission is not active.'; end if;
  if p_question_index <> r.question_index or p_question_index < 0 or p_question_index > 19 then raise exception 'This question is not the current question.'; end if;
  select id into active_player_id from public.mystery_players where room_id=r.id
    order by case character_id when 'conan' then 1 when 'ai' then 2 when 'mitsuhiko' then 3 when 'genta' then 4 else 99 end
    limit 1 offset (r.question_index % 4);
  if active_player_id is distinct from p.id then raise exception 'It is not your turn yet. Watch the screen for your character.'; end if;
  if exists(select 1 from public.mystery_answers where player_id=p.id and question_index=p_question_index) then raise exception 'You already answered this question.'; end if;
  q := r.questions->p_question_index;
  if q is null then raise exception 'Question data is missing.'; end if;
  correct := (q->>'answer')::int = p_answer;
  elapsed := greatest(0,floor(extract(epoch from (clock_timestamp()-coalesce(r.question_started_at,r.updated_at)))*1000)::integer);
  if correct and elapsed <= 10000 then bonus := 1; end if;
  insert into public.mystery_answers(room_id,player_id,question_index,answer,answer_value,is_correct,elapsed_ms,speed_bonus)
    values(r.id,p.id,p_question_index,p_answer,p_answer,correct,elapsed,bonus);
  update public.mystery_players set score=score+case when correct then 1+bonus else 0 end,
    current_question=least(current_question+1,20),last_answer_correct=correct where id=p.id returning score into new_score;
  next_index := r.question_index+1;
  if next_index >= 20 then
    update public.mystery_rooms set status='finished',question_index=20,updated_at=now(),question_started_at=null where id=r.id;
  else
    update public.mystery_rooms set question_index=next_index,updated_at=now(),question_started_at=now() where id=r.id;
  end if;
  return jsonb_build_object('correct',correct,'correct_answer',(q->>'answer')::int,'player_score',new_score,'speed_bonus',bonus,'elapsed_ms',elapsed);
end $$;

create or replace function public.finish_mystery_room(p_room_code text)
returns public.mystery_rooms language plpgsql security definer set search_path = public as $$
declare r public.mystery_rooms;
begin
  if auth.uid() is null or coalesce(auth.jwt()->'app_metadata'->>'role','') <> 'teacher' then raise exception 'Only an authenticated teacher can end a room'; end if;
  select * into r from public.mystery_rooms
  where upper(coalesce(room_code,code))=upper(trim(p_room_code)) or upper(code)=upper(trim(p_room_code))
  order by created_at desc limit 1 for update;
  if not found then raise exception 'Room not found.'; end if;
  update public.mystery_rooms set status='finished',question_index=20,updated_at=now(),question_started_at=null where id=r.id returning * into r;
  return r;
end $$;

grant execute on function public.join_mystery_spectator(text,text) to anon,authenticated;
grant execute on function public.start_mystery_room(text) to authenticated;
grant execute on function public.finish_mystery_room(text) to authenticated;
grant execute on function public.join_mystery_room(text,text,text) to anon,authenticated;
grant execute on function public.submit_mystery_answer(uuid,integer,integer) to anon,authenticated;
revoke all on function public.create_mystery_room() from public,anon,authenticated;
revoke all on function public.submit_mystery_answer(uuid,integer,integer,boolean) from public,anon,authenticated;

do $$ begin
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='mystery_spectators') then
    alter publication supabase_realtime add table public.mystery_spectators;
  end if;
end $$;
