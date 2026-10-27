alter table public.mystery_rooms
  add column if not exists question_clock_started boolean not null default false;

create or replace function public.start_mystery_question_clock(p_player_id uuid,p_question_index integer)
returns boolean language plpgsql security definer set search_path = public as $$
declare p public.mystery_players; r public.mystery_rooms; active_player_id uuid;
begin
  select * into p from public.mystery_players where id=p_player_id;
  if not found then raise exception 'Player not found.'; end if;
  select * into r from public.mystery_rooms where id=p.room_id for update;
  if r.status <> 'playing' or r.question_index <> p_question_index then raise exception 'This question is not active.'; end if;
  select id into active_player_id from public.mystery_players where room_id=r.id
    order by case character_id when 'conan' then 1 when 'ai' then 2 when 'mitsuhiko' then 3 when 'genta' then 4 else 99 end
    limit 1 offset (r.question_index % 4);
  if active_player_id is distinct from p.id then raise exception 'Only the active detective can start this question clock.'; end if;
  if r.question_clock_started then return false; end if;
  update public.mystery_rooms set question_started_at=now(),question_clock_started=true,updated_at=now() where id=r.id;
  return true;
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
  update public.mystery_rooms set status='playing',question_index=0,question_started_at=null,question_clock_started=false,updated_at=now() where id=r.id returning * into r;
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
  if r.question_clock_started and r.question_started_at is not null then elapsed := greatest(0,floor(extract(epoch from (clock_timestamp()-r.question_started_at))*1000)::integer); else elapsed := 999999; end if;
  if correct and elapsed <= 10000 then bonus := 1; end if;
  insert into public.mystery_answers(room_id,player_id,question_index,answer,answer_value,is_correct,elapsed_ms,speed_bonus)
    values(r.id,p.id,p_question_index,p_answer,p_answer,correct,elapsed,bonus);
  update public.mystery_players set score=score+case when correct then 1+bonus else 0 end,current_question=least(current_question+1,20),last_answer_correct=correct where id=p.id returning score into new_score;
  next_index := r.question_index+1;
  if next_index >= 20 then update public.mystery_rooms set status='finished',question_index=20,updated_at=now(),question_started_at=null,question_clock_started=false where id=r.id;
  else update public.mystery_rooms set question_index=next_index,updated_at=now(),question_started_at=null,question_clock_started=false where id=r.id; end if;
  return jsonb_build_object('correct',correct,'correct_answer',(q->>'answer')::int,'player_score',new_score,'speed_bonus',bonus,'elapsed_ms',elapsed);
end $$;

grant execute on function public.start_mystery_question_clock(uuid,integer) to anon,authenticated;
